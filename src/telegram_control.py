#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Secure Telegram command polling for Aliyun Guard."""

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

BOT_COMMANDS = [
    {"command": "status", "description": "查看最近检测状态"},
    {"command": "instances", "description": "查看监控实例"},
    {"command": "check", "description": "立即执行一轮检测"},
    {"command": "poweron", "description": "选择实例开机"},
    {"command": "poweroff", "description": "选择实例关机"},
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

    def _remove_buttons(self, telegram, callback):
        message = callback.get("message", {})
        chat_id = message.get("chat", {}).get("id")
        message_id = message.get("message_id")
        if chat_id is None or message_id is None:
            return
        try:
            self._telegram_api(
                telegram,
                "editMessageReplyMarkup",
                {
                    "chat_id": str(chat_id),
                    "message_id": str(message_id),
                    "reply_markup": json.dumps({"inline_keyboard": []}),
                },
            )
        except Exception:
            pass

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
            ]
        }

    def _send_help(self, telegram, chat_id):
        self._send(
            telegram,
            chat_id,
            "Aliyun Guard Bot 控制\n\n"
            "/status - 查看最近检测状态\n"
            "/instances - 查看监控实例\n"
            "/check - 立即执行一轮检测\n"
            "/poweron <序号或实例ID> - 开机\n"
            "/poweroff <序号或实例ID> - 关机\n"
            "/help - 显示控制菜单\n\n"
            "检测和关机需要确认；关机状态开机需要连续确认两次。",
            self._menu_markup(),
        )

    def _instance_choices(self, telegram, chat_id, config, action):
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
            self._send(telegram, chat_id, "尚未配置监控实例。")
            return
        self._send(
            telegram,
            chat_id,
            "请选择需要{}的实例：".format(label),
            {"inline_keyboard": rows},
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
                self._send(telegram, chat_id, "实例不存在或配置已经变化。")
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
        self._send(telegram, chat_id, text, markup)

    def _expire_pending(self):
        now = time.monotonic()
        self.pending = {
            token: item
            for token, item in self.pending.items()
            if float(item.get("expires", 0)) > now
        }

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
        if not text.startswith("/"):
            self._send_help(telegram, chat_id)
            return
        parts = text.split()
        command = parts[0].split("@", 1)[0].lower()
        argument = " ".join(parts[1:]).strip()
        if command in ("/start", "/help", "/menu"):
            self._send_help(telegram, chat_id)
        elif command == "/status":
            self._send(telegram, chat_id, build_status_text(self.guard, config=config))
        elif command in ("/instances", "/list"):
            self._send(telegram, chat_id, build_instances_text(self.guard, config=config))
        elif command == "/check":
            self._new_confirmation(telegram, chat_id, user_id, "check")
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
        if action == "check":
            self._send(telegram, chat_id, "正在执行检测，请稍候。")
            with self.guard.cycle_lock() as locked:
                if not locked:
                    self._send(telegram, chat_id, "已有检测任务正在运行，请稍后再试。")
                    return
                code = self.guard.run_cycle(no_notify=True)
                summary = str(self.guard.load_state().get("last_summary", "") or "")
            self._send(
                telegram,
                chat_id,
                summary or "检测已完成，返回状态码 {}。".format(code),
                self._menu_markup(),
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
            self._send(telegram, chat_id, "实例不存在或配置已经变化。")
            return
        import web_panel

        self.guard.LOGGER.info(
            "Telegram 管理员 %s 请求%s实例 %s",
            user_id,
            "启动" if action == "start" else "停止",
            instance_id,
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
        self._send(telegram, chat_id, result["message"], self._menu_markup())

    def _prepare_second_start_confirmation(self, telegram, pending):
        chat_id = pending["chat_id"]
        user_id = pending["user_id"]
        instance_id = str(pending.get("instance_id", ""))
        with self.guard.cycle_lock() as locked:
            if not locked:
                self._send(telegram, chat_id, "已有检测任务正在运行，请稍后重新操作。")
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
                self._send(telegram, chat_id, "实例不存在或配置已经变化。")
                return
            status = self.guard.query_instance_status(user)
            if status == "Running":
                self._send(telegram, chat_id, "实例已经处于运行状态，无需开机。")
                return
            if status != "Stopped":
                self._send(
                    telegram,
                    chat_id,
                    "实例当前状态为 {}，暂不执行开机。".format(status),
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
        )

    def _handle_callback(self, config, telegram, admins, callback):
        callback_id = callback.get("id")
        auth = self._authorized(telegram, admins, callback, callback_id=callback_id)
        if auth is None:
            return
        user_id, chat_id = auth
        data = str(callback.get("data", "") or "")
        if data == "ag:status":
            self._answer_callback(telegram, callback_id)
            self._send(telegram, chat_id, build_status_text(self.guard, config=config))
            return
        if data == "ag:instances":
            self._answer_callback(telegram, callback_id)
            self._send(telegram, chat_id, build_instances_text(self.guard, config=config))
            return
        if data == "ag:req:check":
            self._answer_callback(telegram, callback_id)
            self._new_confirmation(telegram, chat_id, user_id, "check")
            return
        if data.startswith("ag:list:"):
            action = data.rsplit(":", 1)[-1]
            self._answer_callback(telegram, callback_id)
            if action in ("start", "stop"):
                self._instance_choices(telegram, chat_id, config, action)
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
                    self._send(telegram, chat_id, "实例不存在或配置已经变化。")
                    return
                self._new_confirmation(
                    telegram,
                    chat_id,
                    user_id,
                    parts[2],
                    str(user.get("instance_id", "")),
                )
            return
        if data.startswith("ag:cancel:"):
            token = data.split(":", 2)[-1]
            pending = self.pending.get(token)
            if pending and pending.get("user_id") == user_id:
                self.pending.pop(token, None)
                self._remove_buttons(telegram, callback)
                self._answer_callback(telegram, callback_id, "已取消")
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
            self._remove_buttons(telegram, callback)
            self._answer_callback(telegram, callback_id, "正在执行")
            try:
                self._execute_pending(telegram, pending)
            except Exception as exc:
                detail = self.guard.compact_error(
                    exc, secrets=self.guard.telegram_secrets(telegram)
                )
                self.guard.LOGGER.exception("Telegram Bot 控制执行失败: %s", detail)
                self._send(telegram, chat_id, "操作失败: {}".format(detail))
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
