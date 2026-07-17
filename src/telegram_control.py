#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Secure Telegram command polling for Aliyun Guard."""

import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import secrets
import threading
import time


POLL_TIMEOUT_SECONDS = 20
RETRY_WAIT_SECONDS = 5
CONFIRM_TTL_SECONDS = 90
SCHEDULE_INPUT_TTL_SECONDS = 300

BOT_COMMANDS = [
    {"command": "status", "description": "查看最近检测状态"},
    {"command": "instances", "description": "查看监控实例"},
    {"command": "check", "description": "立即执行一轮检测"},
    {"command": "poweron", "description": "选择实例开机"},
    {"command": "poweroff", "description": "选择实例关机"},
    {"command": "schedule", "description": "管理定时开关机"},
    {"command": "help", "description": "显示控制菜单"},
]


def _token_fingerprint(token):
    return hashlib.sha256(str(token or "").encode("utf-8")).hexdigest()[:24]


def _control_state_path(guard):
    configured = os.environ.get("ALIYUN_GUARD_TELEGRAM_CONTROL_STATE")
    if configured:
        return Path(configured)
    return guard.STATE_FILE.with_name("telegram-control-state.json")


def _load_offset(guard, fingerprint):
    path = _control_state_path(guard)
    try:
        data = guard.load_json(path, {})
        if data.get("token_fingerprint") != fingerprint:
            return None
        offset = int(data.get("offset", 0))
        return max(0, offset)
    except Exception:
        return None


def _save_offset(guard, fingerprint, offset):
    guard.atomic_write_json(
        _control_state_path(guard),
        {"token_fingerprint": fingerprint, "offset": max(0, int(offset))},
        mode=0o600,
    )


def _format_traffic(value):
    try:
        return "{:.2f} GB".format(float(value))
    except (TypeError, ValueError):
        return "暂无"


def build_status_text(guard, config=None, state=None):
    config = config or guard.load_config()
    state = state or guard.load_state()
    finished = state.get("last_cycle_finished_at") or "尚未完成检测"
    if state.get("last_cycle_finished_at"):
        result = "正常" if state.get("last_cycle_ok") else "存在错误"
    else:
        result = "暂无"
    lines = [
        "Aliyun Guard 状态",
        "最近检测: {}".format(finished),
        "检测结果: {}".format(result),
        "检测次数: {}".format(int(state.get("cycle_count", 0) or 0)),
        "监控实例: {} 个".format(len(config.get("users", []))),
    ]
    telegram_error = str(state.get("telegram_error", "") or "").strip()
    if telegram_error:
        lines.append("通知状态: 上次发送失败")
    return "\n".join(lines)


def build_instances_text(guard, config=None, state=None):
    config = config or guard.load_config()
    state = state or guard.load_state()
    previous = state.get("instances", {})
    if not isinstance(previous, dict):
        previous = {}
    users = config.get("users", [])
    if not users:
        return "尚未配置监控实例。"
    lines = ["监控实例"]
    for index, user in enumerate(users, 1):
        instance_id = str(user.get("instance_id", ""))
        current = previous.get(instance_id, {})
        if not isinstance(current, dict):
            current = {}
        status = current.get("status_after") or "Unknown"
        mode = "已暂停" if user.get("paused") else "监控中"
        lines.extend(
            [
                "",
                "#{:d} {}".format(index, user.get("name") or instance_id),
                "ID: {}".format(instance_id),
                "状态: {} · {}".format(status, mode),
                "流量: {} / {:.2f} GB".format(
                    _format_traffic(current.get("traffic_gb")),
                    float(user.get("traffic_limit_gb", 0) or 0),
                ),
            ]
        )
    return "\n".join(lines)


def resolve_instance(config, selector):
    users = config.get("users", [])
    selector = str(selector or "").strip()
    if selector.isdigit():
        index = int(selector) - 1
        if 0 <= index < len(users):
            return users[index]
    exact = [
        user
        for user in users
        if selector
        and selector.casefold()
        in {
            str(user.get("instance_id", "")).casefold(),
            str(user.get("name", "")).casefold(),
        }
    ]
    return exact[0] if len(exact) == 1 else None


def build_schedule_text(guard, user, now=None):
    now = now or dt.datetime.now().astimezone()
    schedule = guard.get_schedule_config(user)
    name = str(user.get("name") or user.get("instance_id", ""))
    lines = [
        "定时开关机",
        "实例: {} ({})".format(name, user.get("instance_id", "")),
        "服务器时间: {}".format(now.strftime("%Y-%m-%d %H:%M %Z%z")),
        "计划状态: {}".format("已启用" if schedule["enabled"] else "已关闭"),
        "每日开机: {}".format(schedule["start_time"]),
        "每日关机: {}".format(schedule["stop_time"]),
    ]
    if schedule["enabled"]:
        target = guard.schedule_target(user, now)
        event = guard.next_schedule_event(user, now)
        lines.append(
            "运行时段: {}".format(
                "跨午夜" if schedule["start_time"] > schedule["stop_time"] else "当日"
            )
        )
        lines.append("当前目标: {}".format("运行" if target == "running" else "关机"))
        if event:
            event_time, action = event
            lines.append(
                "下一动作: {} {}".format(
                    event_time.strftime("%Y-%m-%d %H:%M"),
                    "开机" if action == "start" else "关机",
                )
            )
    if user.get("paused"):
        lines.append("提示: 实例监控已暂停，计划暂不执行。")
    else:
        lines.append("提示: 达到流量阈值时不会执行计划开机。")
    return "\n".join(lines)


class TelegramControlService:
    def __init__(self, guard):
        self.guard = guard
        self.stop_event = threading.Event()
        self.thread = threading.Thread(
            target=self._run,
            name="aliyun-guard-telegram-control",
            daemon=True,
        )
        self.pending = {}
        self.schedule_inputs = {}
        self.offset = None
        self.fingerprint = None
        self.commands_fingerprint = None
        self.last_error = None
        self.last_inactive_reason = None
        self.drain_pending = True

    def start(self):
        self.thread.start()
        return self

    def shutdown(self):
        self.stop_event.set()
        self.thread.join(timeout=POLL_TIMEOUT_SECONDS + 5)

    def _log_inactive(self, reason):
        if reason != self.last_inactive_reason:
            self.guard.LOGGER.info("Telegram Bot 控制未运行: %s", reason)
            self.last_inactive_reason = reason

    def _poll_config(self):
        config = self.guard.load_config()
        telegram = config.get("telegram", {})
        if not telegram.get("control_enabled", True):
            self.drain_pending = True
            self._log_inactive("已在配置中关闭")
            return None, None, None
        if not str(telegram.get("bot_token", "") or "").strip():
            self.drain_pending = True
            self._log_inactive("Bot Token 未配置")
            return None, None, None
        admins = self.guard.telegram_control_admin_ids(telegram)
        if not admins:
            self.drain_pending = True
            self._log_inactive("未配置有效的管理员用户 ID")
            return None, None, None
        self.last_inactive_reason = None
        return config, telegram, set(admins)

    def _telegram_api(self, telegram, method, data=None, long_poll=False):
        candidate = dict(telegram)
        if long_poll:
            candidate["retries"] = 1
        request_timeout = POLL_TIMEOUT_SECONDS + 10 if long_poll else None
        return self.guard.telegram_api(
            candidate,
            method,
            data or {},
            request_timeout=request_timeout,
        )

    def _send(self, telegram, chat_id, text, reply_markup=None):
        chunks = self.guard.split_message(str(text or ""))
        result = None
        for index, chunk in enumerate(chunks):
            data = {"chat_id": str(chat_id), "text": chunk}
            if reply_markup is not None and index == len(chunks) - 1:
                data["reply_markup"] = json.dumps(reply_markup, ensure_ascii=False)
            result = self._telegram_api(telegram, "sendMessage", data)
        return result

    @staticmethod
    def _callback_message_ref(callback):
        message = callback.get("message", {}) if isinstance(callback, dict) else {}
        chat_id = message.get("chat", {}).get("id")
        message_id = message.get("message_id")
        if chat_id is None or message_id is None:
            return None, None
        return int(chat_id), int(message_id)

    def _edit(self, telegram, chat_id, message_id, text, reply_markup=None):
        chunks = self.guard.split_message(str(text or ""))
        if len(chunks) != 1:
            return self._send(telegram, chat_id, text, reply_markup)
        data = {
            "chat_id": str(chat_id),
            "message_id": str(message_id),
            "text": chunks[0],
            "reply_markup": json.dumps(
                reply_markup or {"inline_keyboard": []}, ensure_ascii=False
            ),
        }
        try:
            return self._telegram_api(telegram, "editMessageText", data)
        except Exception as exc:
            detail = self.guard.compact_error(exc)
            if "message is not modified" in detail.lower():
                return None
            self.guard.LOGGER.warning("Telegram 消息编辑失败，改为发送新消息: %s", detail)
            return self._send(telegram, chat_id, text, reply_markup)

    def _display(self, telegram, chat_id, text, reply_markup=None, message_id=None):
        if message_id is not None:
            return self._edit(
                telegram, chat_id, message_id, text, reply_markup=reply_markup
            )
        return self._send(telegram, chat_id, text, reply_markup)

    def _edit_callback(self, telegram, callback, text, reply_markup=None):
        chat_id, message_id = self._callback_message_ref(callback)
        if chat_id is None:
            return None
        return self._edit(
            telegram, chat_id, message_id, text, reply_markup=reply_markup
        )

    def _answer_callback(self, telegram, callback_id, text="", alert=False):
        data = {
            "callback_query_id": str(callback_id),
            "text": str(text or "")[:190],
            "show_alert": "true" if alert else "false",
        }
        try:
            self._telegram_api(telegram, "answerCallbackQuery", data)
        except Exception as exc:
            self.guard.LOGGER.warning("Telegram 回调确认失败: %s", self.guard.compact_error(exc))

    @staticmethod
    def _menu_markup():
        return {
            "inline_keyboard": [
                [
                    {"text": "状态", "callback_data": "ag:status"},
                    {"text": "实例", "callback_data": "ag:instances"},
                ],
                [{"text": "立即检测", "callback_data": "ag:req:check"}],
                [
                    {"text": "实例开机", "callback_data": "ag:list:start"},
                    {"text": "实例关机", "callback_data": "ag:list:stop"},
                ],
                [{"text": "定时计划", "callback_data": "ag:schedule"}],
            ]
        }

    @staticmethod
    def _main_text():
        return (
            "Aliyun Guard Bot 控制\n\n"
            "/status - 查看最近检测状态\n"
            "/instances - 查看监控实例\n"
            "/check - 立即执行一轮检测\n"
            "/poweron <序号或实例ID> - 开机\n"
            "/poweroff <序号或实例ID> - 关机\n"
            "/schedule [序号或实例ID] - 定时计划\n"
            "/help - 显示控制菜单\n\n"
            "检测和关机需要确认；关机状态开机需要连续确认两次。"
        )

    @staticmethod
    def _view_markup(refresh_data):
        return {
            "inline_keyboard": [
                [
                    {"text": "刷新", "callback_data": refresh_data},
                    {"text": "返回主菜单", "callback_data": "ag:menu"},
                ]
            ]
        }

    def _send_help(self, telegram, chat_id, message_id=None):
        self._display(
            telegram,
            chat_id,
            self._main_text(),
            self._menu_markup(),
            message_id=message_id,
        )

    def _show_status(self, telegram, chat_id, config, message_id=None):
        self._display(
            telegram,
            chat_id,
            build_status_text(self.guard, config=config),
            self._view_markup("ag:status"),
            message_id=message_id,
        )

    def _show_instances(self, telegram, chat_id, config, message_id=None):
        self._display(
            telegram,
            chat_id,
            build_instances_text(self.guard, config=config),
            self._view_markup("ag:instances"),
            message_id=message_id,
        )

    def _instance_choices(self, telegram, chat_id, config, action, message_id=None):
        label = "开机" if action == "start" else "关机"
        rows = []
        for index, user in enumerate(config.get("users", [])):
            name = str(user.get("name") or user.get("instance_id"))[:32]
            rows.append(
                [
                    {
                        "text": "{} {}".format(label, name),
                        "callback_data": "ag:req:{}:{}".format(action, index),
                    }
                ]
            )
        if not rows:
            self._display(
                telegram,
                chat_id,
                "尚未配置监控实例。",
                self._view_markup("ag:list:{}".format(action)),
                message_id=message_id,
            )
            return
        rows.append([{"text": "返回主菜单", "callback_data": "ag:menu"}])
        self._display(
            telegram,
            chat_id,
            "请选择需要{}的实例：".format(label),
            {"inline_keyboard": rows},
            message_id=message_id,
        )

    def _schedule_choices(self, telegram, chat_id, config, message_id=None):
        rows = []
        for index, user in enumerate(config.get("users", [])):
            schedule = self.guard.get_schedule_config(user)
            name = str(user.get("name") or user.get("instance_id"))[:24]
            suffix = (
                "{}-{}".format(schedule["start_time"], schedule["stop_time"])
                if schedule["enabled"]
                else "已关闭"
            )
            rows.append(
                [
                    {
                        "text": "{} · {}".format(name, suffix),
                        "callback_data": "ag:sched:view:{}".format(index),
                    }
                ]
            )
        rows.append([{"text": "返回主菜单", "callback_data": "ag:menu"}])
        text = "请选择需要管理定时计划的实例："
        if not config.get("users", []):
            text = "尚未配置监控实例。"
        self._display(
            telegram,
            chat_id,
            text,
            {"inline_keyboard": rows},
            message_id=message_id,
        )

    def _schedule_detail(self, telegram, chat_id, config, index, message_id=None):
        users = config.get("users", [])
        if index < 0 or index >= len(users):
            self._display(
                telegram,
                chat_id,
                "实例不存在或配置已经变化。",
                self._view_markup("ag:schedule"),
                message_id=message_id,
            )
            return
        user = users[index]
        schedule = self.guard.get_schedule_config(user)
        toggle_label = "关闭计划" if schedule["enabled"] else "启用计划"
        markup = {
            "inline_keyboard": [
                [
                    {
                        "text": "修改时间",
                        "callback_data": "ag:sched:edit:{}".format(index),
                    },
                    {
                        "text": toggle_label,
                        "callback_data": "ag:sched:ask:{}".format(index),
                    },
                ],
                [
                    {
                        "text": "刷新",
                        "callback_data": "ag:sched:view:{}".format(index),
                    },
                    {"text": "返回实例列表", "callback_data": "ag:schedule"},
                ],
                [{"text": "返回主菜单", "callback_data": "ag:menu"}],
            ]
        }
        self._display(
            telegram,
            chat_id,
            build_schedule_text(self.guard, user),
            markup,
            message_id=message_id,
        )

    def _new_confirmation(
        self,
        telegram,
        chat_id,
        user_id,
        action,
        instance_id=None,
        stage=1,
        threshold_override=False,
        traffic_gb=None,
        limit_gb=None,
        message_id=None,
    ):
        self._expire_pending()
        self.pending = {
            token: item
            for token, item in self.pending.items()
            if item.get("user_id") != int(user_id)
        }
        token = secrets.token_urlsafe(9)
        self.pending[token] = {
            "user_id": int(user_id),
            "chat_id": int(chat_id),
            "action": action,
            "instance_id": instance_id,
            "stage": int(stage),
            "threshold_override": bool(threshold_override),
            "message_id": message_id,
            "expires": time.monotonic() + CONFIRM_TTL_SECONDS,
        }
        if action == "check":
            text = "确认立即执行一轮真实检测？检测可能根据当前规则执行开关机。"
        else:
            config = self.guard.load_config()
            user = next(
                (
                    item
                    for item in config.get("users", [])
                    if str(item.get("instance_id", "")) == str(instance_id)
                ),
                None,
            )
            if user is None:
                self.pending.pop(token, None)
                self._display(
                    telegram,
                    chat_id,
                    "实例不存在或配置已经变化。",
                    self._menu_markup(),
                    message_id=message_id,
                )
                return
            label = "开机" if action == "start" else "关机"
            if action == "start" and int(stage) == 1:
                text = "第一次确认：准备{}实例 {}（{}）？".format(
                    label,
                    user.get("name") or instance_id,
                    instance_id,
                )
            elif action == "start" and threshold_override:
                text = (
                    "第二次确认：当前 CDT 流量 {:.2f} GB 已达到 {:.2f} GB 阈值。\n"
                    "继续将强制开机，并自动暂停该实例监控。"
                ).format(float(traffic_gb), float(limit_gb))
            elif action == "start":
                text = "第二次确认：实例当前已关机，确认执行开机？"
            else:
                text = "确认{}实例 {}（{}）？".format(
                    label,
                    user.get("name") or instance_id,
                    instance_id,
                )
        markup = {
            "inline_keyboard": [
                [
                    {"text": "确认执行", "callback_data": "ag:confirm:{}".format(token)},
                    {"text": "取消", "callback_data": "ag:cancel:{}".format(token)},
                ]
            ]
        }
        self._display(
            telegram,
            chat_id,
            text,
            markup,
            message_id=message_id,
        )

    def _expire_pending(self):
        now = time.monotonic()
        self.pending = {
            token: item
            for token, item in self.pending.items()
            if float(item.get("expires", 0)) > now
        }

    def _prompt_schedule_input(
        self, telegram, chat_id, user_id, config, index, message_id
    ):
        users = config.get("users", [])
        if index < 0 or index >= len(users):
            self._display(
                telegram,
                chat_id,
                "实例不存在或配置已经变化。",
                self._view_markup("ag:schedule"),
                message_id=message_id,
            )
            return
        user = users[index]
        schedule = self.guard.get_schedule_config(user)
        self.schedule_inputs[int(user_id)] = {
            "chat_id": int(chat_id),
            "message_id": int(message_id),
            "instance_id": str(user.get("instance_id", "")),
            "expires": time.monotonic() + SCHEDULE_INPUT_TTL_SECONDS,
        }
        text = (
            "修改定时计划\n\n"
            "实例: {} ({})\n"
            "当前时间: {} 开机，{} 关机\n\n"
            "请发送新的开机和关机时间：\n"
            "格式: HH:MM HH:MM\n"
            "示例: 08:30 23:15\n\n"
            "输入有效期 5 分钟。"
        ).format(
            user.get("name") or user.get("instance_id"),
            user.get("instance_id", ""),
            schedule["start_time"],
            schedule["stop_time"],
        )
        self._display(
            telegram,
            chat_id,
            text,
            {
                "inline_keyboard": [
                    [
                        {
                            "text": "取消修改",
                            "callback_data": "ag:sched:view:{}".format(index),
                        }
                    ]
                ]
            },
            message_id=message_id,
        )

    def _handle_schedule_input(self, telegram, user_id, chat_id, text):
        pending = self.schedule_inputs.get(int(user_id))
        if pending is None or pending.get("chat_id") != int(chat_id):
            return False
        if float(pending.get("expires", 0)) <= time.monotonic():
            self.schedule_inputs.pop(int(user_id), None)
            self._display(
                telegram,
                chat_id,
                "时间输入已过期，请重新进入定时计划修改。",
                self._view_markup("ag:schedule"),
                message_id=pending.get("message_id"),
            )
            return True
        if text.startswith("/") and text.lower() != "/cancel":
            self.schedule_inputs.pop(int(user_id), None)
            return False
        message_id = pending.get("message_id")
        instance_id = str(pending.get("instance_id", ""))
        if text.lower() == "/cancel":
            self.schedule_inputs.pop(int(user_id), None)
            config = self.guard.load_config()
            index = next(
                (
                    index
                    for index, user in enumerate(config.get("users", []))
                    if str(user.get("instance_id", "")) == instance_id
                ),
                -1,
            )
            self._schedule_detail(
                telegram, chat_id, config, index, message_id=message_id
            )
            return True
        try:
            parts = text.replace(",", " ").split()
            if len(parts) != 2:
                raise self.guard.GuardError("请同时输入开机时间和关机时间")
            start_time = self.guard.normalize_schedule_time(parts[0], "开机时间")
            stop_time = self.guard.normalize_schedule_time(parts[1], "关机时间")
            if start_time == stop_time:
                raise self.guard.GuardError("开机时间和关机时间不能相同")
            with self.guard.cycle_lock() as locked:
                if not locked:
                    raise self.guard.GuardError("检测任务正在运行，请稍后重新输入")
                config = self.guard.load_config()
                index = next(
                    (
                        index
                        for index, user in enumerate(config.get("users", []))
                        if str(user.get("instance_id", "")) == instance_id
                    ),
                    None,
                )
                if index is None:
                    raise self.guard.GuardError("实例不存在或配置已经变化")
                user = config["users"][index]
                schedule = self.guard.get_schedule_config(user)
                user["schedule"] = {
                    "enabled": bool(schedule["enabled"]),
                    "start_time": start_time,
                    "stop_time": stop_time,
                }
                self.guard.validate_config(config)
                self.guard.atomic_write_json(self.guard.CONFIG_FILE, config, mode=0o600)
            self.schedule_inputs.pop(int(user_id), None)
            self.guard.LOGGER.info(
                "Telegram 管理员 %s 修改实例 %s 定时计划为 %s-%s",
                user_id,
                instance_id,
                start_time,
                stop_time,
            )
            self._schedule_detail(
                telegram, chat_id, config, index, message_id=message_id
            )
        except Exception as exc:
            detail = self.guard.compact_error(exc)
            self._display(
                telegram,
                chat_id,
                "定时计划保存失败: {}\n\n请重新发送，例如：08:30 23:15".format(
                    detail
                ),
                {
                    "inline_keyboard": [
                        [{"text": "取消修改", "callback_data": "ag:schedule"}]
                    ]
                },
                message_id=message_id,
            )
        return True

    def _confirm_schedule_toggle(
        self, telegram, chat_id, config, index, message_id=None
    ):
        users = config.get("users", [])
        if index < 0 or index >= len(users):
            self._schedule_choices(
                telegram, chat_id, config, message_id=message_id
            )
            return
        user = users[index]
        schedule = self.guard.get_schedule_config(user)
        enabled = not schedule["enabled"]
        action = "启用" if enabled else "关闭"
        effect = (
            "启用后，后台会在 1 分钟内按当前时段执行计划。"
            if enabled
            else "关闭后不会立即改变实例当前状态。"
        )
        text = (
            "确认{}定时计划？\n\n"
            "实例: {} ({})\n"
            "每日开机: {}\n"
            "每日关机: {}\n\n{}"
        ).format(
            action,
            user.get("name") or user.get("instance_id"),
            user.get("instance_id", ""),
            schedule["start_time"],
            schedule["stop_time"],
            effect,
        )
        self._display(
            telegram,
            chat_id,
            text,
            {
                "inline_keyboard": [
                    [
                        {
                            "text": "确认{}".format(action),
                            "callback_data": "ag:sched:set:{}:{}".format(
                                index, 1 if enabled else 0
                            ),
                        },
                        {
                            "text": "取消",
                            "callback_data": "ag:sched:view:{}".format(index),
                        },
                    ]
                ]
            },
            message_id=message_id,
        )

    def _set_schedule_enabled(
        self, telegram, chat_id, user_id, index, enabled, message_id=None
    ):
        with self.guard.cycle_lock() as locked:
            if not locked:
                raise self.guard.GuardError("检测任务正在运行，请稍后再试")
            config = self.guard.load_config()
            users = config.get("users", [])
            if index < 0 or index >= len(users):
                raise self.guard.GuardError("实例不存在或配置已经变化")
            user = users[index]
            schedule = self.guard.get_schedule_config(user)
            user["schedule"] = {
                "enabled": bool(enabled),
                "start_time": schedule["start_time"],
                "stop_time": schedule["stop_time"],
            }
            self.guard.validate_config(config)
            self.guard.atomic_write_json(self.guard.CONFIG_FILE, config, mode=0o600)
        self.guard.LOGGER.info(
            "Telegram 管理员 %s %s实例 %s 定时计划",
            user_id,
            "启用" if enabled else "关闭",
            user.get("instance_id", ""),
        )
        self._schedule_detail(
            telegram, chat_id, config, index, message_id=message_id
        )

    def _authorized(self, telegram, admins, source, callback_id=None):
        user_id = source.get("from", {}).get("id")
        chat = source.get("chat")
        if chat is None:
            chat = source.get("message", {}).get("chat", {})
        chat_id = chat.get("id")
        if chat.get("type") != "private":
            self.guard.LOGGER.warning("Telegram Bot 控制忽略非私聊命令: %s", chat_id)
            if callback_id:
                self._answer_callback(telegram, callback_id, "仅支持私聊", alert=True)
            return None
        if user_id not in admins:
            self.guard.LOGGER.warning("Telegram Bot 控制拒绝未授权用户: %s", user_id)
            if callback_id:
                self._answer_callback(telegram, callback_id, "无权限", alert=True)
            elif chat_id is not None:
                self._send(telegram, chat_id, "无权限。")
            return None
        return int(user_id), int(chat_id)

    def _handle_message(self, config, telegram, admins, message):
        auth = self._authorized(telegram, admins, message)
        if auth is None:
            return
        user_id, chat_id = auth
        text = str(message.get("text", "") or "").strip()
        if self._handle_schedule_input(telegram, user_id, chat_id, text):
            return
        if not text.startswith("/"):
            self._send_help(telegram, chat_id)
            return
        parts = text.split()
        command = parts[0].split("@", 1)[0].lower()
        argument = " ".join(parts[1:]).strip()
        if command in ("/start", "/help", "/menu"):
            self._send_help(telegram, chat_id)
        elif command == "/status":
            self._show_status(telegram, chat_id, config)
        elif command in ("/instances", "/list"):
            self._show_instances(telegram, chat_id, config)
        elif command == "/check":
            self._new_confirmation(telegram, chat_id, user_id, "check")
        elif command in ("/schedule", "/plan"):
            if not argument:
                self._schedule_choices(telegram, chat_id, config)
                return
            user = resolve_instance(config, argument)
            if user is None:
                self._send(
                    telegram,
                    chat_id,
                    "实例不存在，请使用 /instances 查看序号。",
                    self._view_markup("ag:schedule"),
                )
                return
            index = config.get("users", []).index(user)
            self._schedule_detail(telegram, chat_id, config, index)
        elif command in ("/poweron", "/on", "/poweroff", "/off"):
            action = "start" if command in ("/poweron", "/on") else "stop"
            if not argument:
                self._instance_choices(telegram, chat_id, config, action)
                return
            user = resolve_instance(config, argument)
            if user is None:
                self._send(telegram, chat_id, "实例不存在，请使用 /instances 查看序号。")
                return
            self._new_confirmation(
                telegram,
                chat_id,
                user_id,
                action,
                str(user.get("instance_id", "")),
            )
        else:
            self._send_help(telegram, chat_id)

    def _execute_pending(self, telegram, pending):
        chat_id = pending["chat_id"]
        user_id = pending["user_id"]
        action = pending["action"]
        message_id = pending.get("message_id")
        if action == "check":
            self._display(
                telegram,
                chat_id,
                "正在执行检测，请稍候。",
                message_id=message_id,
            )
            with self.guard.cycle_lock() as locked:
                if not locked:
                    self._display(
                        telegram,
                        chat_id,
                        "已有检测任务正在运行，请稍后再试。",
                        self._menu_markup(),
                        message_id=message_id,
                    )
                    return
                code = self.guard.run_cycle(no_notify=True)
                summary = str(self.guard.load_state().get("last_summary", "") or "")
            self._display(
                telegram,
                chat_id,
                summary or "检测已完成，返回状态码 {}。".format(code),
                self._menu_markup(),
                message_id=message_id,
            )
            self.guard.LOGGER.info("Telegram 管理员 %s 执行了一轮检测", user_id)
            return

        if action == "start" and int(pending.get("stage", 1)) == 1:
            self._prepare_second_start_confirmation(telegram, pending)
            return

        config = self.guard.load_config()
        instance_id = str(pending.get("instance_id", ""))
        index = next(
            (
                index
                for index, user in enumerate(config.get("users", []))
                if str(user.get("instance_id", "")) == instance_id
            ),
            None,
        )
        if index is None:
            self._display(
                telegram,
                chat_id,
                "实例不存在或配置已经变化。",
                self._menu_markup(),
                message_id=message_id,
            )
            return
        import web_panel

        self.guard.LOGGER.info(
            "Telegram 管理员 %s 请求%s实例 %s",
            user_id,
            "启动" if action == "start" else "停止",
            instance_id,
        )
        self._display(
            telegram,
            chat_id,
            "正在{}实例 {}，请稍候。".format(
                "启动" if action == "start" else "停止", instance_id
            ),
            message_id=message_id,
        )
        result = web_panel.control_instance(
            self.guard,
            index,
            action,
            source="Telegram Bot",
            notify=False,
            allow_threshold_override=bool(pending.get("threshold_override", False)),
            pause_on_threshold_override=True,
        )
        self._display(
            telegram,
            chat_id,
            result["message"],
            self._menu_markup(),
            message_id=message_id,
        )

    def _prepare_second_start_confirmation(self, telegram, pending):
        chat_id = pending["chat_id"]
        user_id = pending["user_id"]
        instance_id = str(pending.get("instance_id", ""))
        message_id = pending.get("message_id")
        with self.guard.cycle_lock() as locked:
            if not locked:
                self._display(
                    telegram,
                    chat_id,
                    "已有检测任务正在运行，请稍后重新操作。",
                    self._menu_markup(),
                    message_id=message_id,
                )
                return
            config = self.guard.load_config()
            user = next(
                (
                    item
                    for item in config.get("users", [])
                    if str(item.get("instance_id", "")) == instance_id
                ),
                None,
            )
            if user is None:
                self._display(
                    telegram,
                    chat_id,
                    "实例不存在或配置已经变化。",
                    self._menu_markup(),
                    message_id=message_id,
                )
                return
            status = self.guard.query_instance_status(user)
            if status == "Running":
                self._display(
                    telegram,
                    chat_id,
                    "实例已经处于运行状态，无需开机。",
                    self._menu_markup(),
                    message_id=message_id,
                )
                return
            if status != "Stopped":
                self._display(
                    telegram,
                    chat_id,
                    "实例当前状态为 {}，暂不执行开机。".format(status),
                    self._menu_markup(),
                    message_id=message_id,
                )
                return
            traffic = self.guard.query_cdt_traffic_gb(user)
            limit = float(user.get("traffic_limit_gb", 0) or 0)
        self._new_confirmation(
            telegram,
            chat_id,
            user_id,
            "start",
            instance_id,
            stage=2,
            threshold_override=traffic >= limit,
            traffic_gb=traffic,
            limit_gb=limit,
            message_id=message_id,
        )

    def _handle_callback(self, config, telegram, admins, callback):
        callback_id = callback.get("id")
        auth = self._authorized(telegram, admins, callback, callback_id=callback_id)
        if auth is None:
            return
        user_id, chat_id = auth
        _callback_chat_id, message_id = self._callback_message_ref(callback)
        data = str(callback.get("data", "") or "")
        self.schedule_inputs.pop(int(user_id), None)
        if not data.startswith(("ag:confirm:", "ag:cancel:")):
            self.pending = {
                token: item
                for token, item in self.pending.items()
                if item.get("user_id") != int(user_id)
            }
        if data == "ag:menu":
            self._answer_callback(telegram, callback_id)
            self._send_help(telegram, chat_id, message_id=message_id)
            return
        if data == "ag:status":
            self._answer_callback(telegram, callback_id)
            self._show_status(telegram, chat_id, config, message_id=message_id)
            return
        if data == "ag:instances":
            self._answer_callback(telegram, callback_id)
            self._show_instances(telegram, chat_id, config, message_id=message_id)
            return
        if data == "ag:schedule":
            self._answer_callback(telegram, callback_id)
            self._schedule_choices(telegram, chat_id, config, message_id=message_id)
            return
        if data.startswith("ag:sched:view:"):
            try:
                index = int(data.rsplit(":", 1)[-1])
            except ValueError:
                self._answer_callback(telegram, callback_id, "实例序号无效", alert=True)
                return
            self._answer_callback(telegram, callback_id)
            self._schedule_detail(
                telegram, chat_id, config, index, message_id=message_id
            )
            return
        if data.startswith("ag:sched:edit:"):
            try:
                index = int(data.rsplit(":", 1)[-1])
            except ValueError:
                self._answer_callback(telegram, callback_id, "实例序号无效", alert=True)
                return
            self._answer_callback(telegram, callback_id)
            self._prompt_schedule_input(
                telegram, chat_id, user_id, config, index, message_id
            )
            return
        if data.startswith("ag:sched:ask:"):
            try:
                index = int(data.rsplit(":", 1)[-1])
            except ValueError:
                self._answer_callback(telegram, callback_id, "实例序号无效", alert=True)
                return
            self._answer_callback(telegram, callback_id)
            self._confirm_schedule_toggle(
                telegram, chat_id, config, index, message_id=message_id
            )
            return
        if data.startswith("ag:sched:set:"):
            parts = data.split(":")
            if len(parts) != 5 or parts[4] not in ("0", "1"):
                self._answer_callback(telegram, callback_id, "计划操作无效", alert=True)
                return
            try:
                index = int(parts[3])
            except ValueError:
                self._answer_callback(telegram, callback_id, "实例序号无效", alert=True)
                return
            self._answer_callback(telegram, callback_id, "正在保存")
            try:
                self._set_schedule_enabled(
                    telegram,
                    chat_id,
                    user_id,
                    index,
                    parts[4] == "1",
                    message_id=message_id,
                )
            except Exception as exc:
                detail = self.guard.compact_error(exc)
                self._display(
                    telegram,
                    chat_id,
                    "定时计划保存失败: {}".format(detail),
                    self._view_markup("ag:schedule"),
                    message_id=message_id,
                )
            return
        if data == "ag:req:check":
            self._answer_callback(telegram, callback_id)
            self._new_confirmation(
                telegram,
                chat_id,
                user_id,
                "check",
                message_id=message_id,
            )
            return
        if data.startswith("ag:list:"):
            action = data.rsplit(":", 1)[-1]
            self._answer_callback(telegram, callback_id)
            if action in ("start", "stop"):
                self._instance_choices(
                    telegram, chat_id, config, action, message_id=message_id
                )
            return
        if data.startswith("ag:req:"):
            parts = data.split(":", 3)
            self._answer_callback(telegram, callback_id)
            if len(parts) == 4 and parts[2] in ("start", "stop"):
                try:
                    index = int(parts[3])
                    if index < 0:
                        raise IndexError
                    user = config.get("users", [])[index]
                except (IndexError, TypeError, ValueError):
                    self._display(
                        telegram,
                        chat_id,
                        "实例不存在或配置已经变化。",
                        self._menu_markup(),
                        message_id=message_id,
                    )
                    return
                self._new_confirmation(
                    telegram,
                    chat_id,
                    user_id,
                    parts[2],
                    str(user.get("instance_id", "")),
                    message_id=message_id,
                )
            return
        if data.startswith("ag:cancel:"):
            token = data.split(":", 2)[-1]
            pending = self.pending.get(token)
            if pending and pending.get("user_id") == user_id:
                self.pending.pop(token, None)
                self._answer_callback(telegram, callback_id, "已取消")
                self._send_help(telegram, chat_id, message_id=message_id)
            else:
                self._answer_callback(telegram, callback_id, "操作已失效", alert=True)
            return
        if data.startswith("ag:confirm:"):
            token = data.split(":", 2)[-1]
            self._expire_pending()
            pending = self.pending.get(token)
            if (
                pending is None
                or pending.get("user_id") != user_id
                or pending.get("chat_id") != chat_id
            ):
                self._answer_callback(telegram, callback_id, "确认已过期或无效", alert=True)
                return
            self.pending.pop(token, None)
            pending["message_id"] = message_id
            self._answer_callback(telegram, callback_id, "正在执行")
            try:
                self._execute_pending(telegram, pending)
            except Exception as exc:
                detail = self.guard.compact_error(
                    exc, secrets=self.guard.telegram_secrets(telegram)
                )
                self.guard.LOGGER.exception("Telegram Bot 控制执行失败: %s", detail)
                self._display(
                    telegram,
                    chat_id,
                    "操作失败: {}".format(detail),
                    self._menu_markup(),
                    message_id=message_id,
                )
            return
        self._answer_callback(telegram, callback_id, "按钮无效", alert=True)

    def _handle_update(self, config, telegram, admins, update):
        if isinstance(update.get("message"), dict):
            self._handle_message(config, telegram, admins, update["message"])
        elif isinstance(update.get("callback_query"), dict):
            self._handle_callback(config, telegram, admins, update["callback_query"])

    def _prepare_token(self, telegram):
        fingerprint = _token_fingerprint(telegram.get("bot_token"))
        token_changed = fingerprint != self.fingerprint
        if (
            not token_changed
            and self.offset is not None
            and not self.drain_pending
        ):
            return
        if token_changed:
            self.drain_pending = True
        self.fingerprint = fingerprint
        self.offset = None if self.drain_pending else _load_offset(self.guard, fingerprint)
        if self.offset is None:
            updates = self._telegram_api(
                telegram,
                "getUpdates",
                {
                    "offset": -1,
                    "limit": 1,
                    "timeout": 0,
                    "allowed_updates": json.dumps(["message", "callback_query"]),
                },
            ) or []
            self.offset = (
                max(int(item.get("update_id", -1)) for item in updates) + 1
                if updates
                else 0
            )
            _save_offset(self.guard, fingerprint, self.offset)
            self.guard.LOGGER.info("Telegram Bot 控制已丢弃启用前的待处理消息")
        self.drain_pending = False
        if self.commands_fingerprint != fingerprint:
            try:
                self._telegram_api(
                    telegram,
                    "setMyCommands",
                    {
                        "commands": json.dumps(BOT_COMMANDS, ensure_ascii=False),
                        "scope": json.dumps({"type": "all_private_chats"}),
                    },
                )
            except Exception as exc:
                self.guard.LOGGER.warning(
                    "Telegram Bot 命令菜单注册失败，文本命令仍可使用: %s",
                    self.guard.compact_error(exc),
                )
            self.commands_fingerprint = fingerprint

    def _run(self):
        while not self.stop_event.is_set():
            try:
                config, telegram, admins = self._poll_config()
                if telegram is None:
                    self.stop_event.wait(RETRY_WAIT_SECONDS)
                    continue
                self._prepare_token(telegram)
                updates = self._telegram_api(
                    telegram,
                    "getUpdates",
                    {
                        "offset": self.offset,
                        "limit": 100,
                        "timeout": POLL_TIMEOUT_SECONDS,
                        "allowed_updates": json.dumps(["message", "callback_query"]),
                    },
                    long_poll=True,
                ) or []
                if updates:
                    self.offset = max(
                        int(item.get("update_id", -1)) for item in updates
                    ) + 1
                    _save_offset(self.guard, self.fingerprint, self.offset)
                    latest_config, latest_telegram, latest_admins = self._poll_config()
                    if latest_telegram is None:
                        continue
                    if _token_fingerprint(latest_telegram.get("bot_token")) != self.fingerprint:
                        self.drain_pending = True
                        continue
                    for update in updates:
                        try:
                            self._handle_update(
                                latest_config,
                                latest_telegram,
                                latest_admins,
                                update,
                            )
                        except Exception as exc:
                            self.guard.LOGGER.exception(
                                "Telegram Bot 单条更新处理失败: %s",
                                self.guard.compact_error(
                                    exc,
                                    secrets=self.guard.telegram_secrets(latest_telegram),
                                ),
                            )
                if self.last_error is not None:
                    self.guard.LOGGER.info("Telegram Bot 控制连接已恢复")
                    self.last_error = None
            except Exception as exc:
                detail = self.guard.compact_error(exc)
                if detail != self.last_error:
                    self.guard.LOGGER.warning("Telegram Bot 控制轮询失败: %s", detail)
                    self.last_error = detail
                self.stop_event.wait(RETRY_WAIT_SECONDS)


def start_background(guard):
    return TelegramControlService(guard).start()
