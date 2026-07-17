import contextlib
import copy
from pathlib import Path
import sys
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

import aliyun_guard as guard
import telegram_control
import web_panel


def make_config():
    config = copy.deepcopy(guard.DEFAULT_CONFIG)
    config["telegram"].update(
        {
            "bot_token": "test-token",
            "chat_id": "123",
            "control_enabled": True,
            "control_admin_ids": [123],
        }
    )
    config["users"] = [
        {
            "name": "HK",
            "ak": "test-ak",
            "sk": "test-sk",
            "region": "cn-hongkong",
            "instance_id": "i-test-control",
            "traffic_limit_gb": 180,
            "actions_enabled": True,
            "paused": False,
            "billing": {"enabled": False},
            "schedule": {
                "enabled": False,
                "start_time": "08:00",
                "stop_time": "23:00",
            },
        }
    ]
    return config


def private_message(text, user_id=123):
    return {
        "message_id": 1,
        "from": {"id": user_id},
        "chat": {"id": user_id, "type": "private"},
        "text": text,
    }


def callback(token, user_id=123, callback_id="callback-1"):
    return button_callback(
        "ag:confirm:{}".format(token),
        user_id=user_id,
        callback_id=callback_id,
    )


def button_callback(data, user_id=123, callback_id="callback-1", message_id=10):
    return {
        "id": callback_id,
        "from": {"id": user_id},
        "message": {
            "message_id": message_id,
            "chat": {"id": user_id, "type": "private"},
        },
        "data": data,
    }


class TelegramControlTests(unittest.TestCase):
    def setUp(self):
        self.config = make_config()
        self.telegram = self.config["telegram"]
        self.service = telegram_control.TelegramControlService(guard)

    def test_status_and_instance_text_do_not_expose_credentials(self):
        state = {
            "last_cycle_finished_at": "2026-07-18T01:00:00+08:00",
            "last_cycle_ok": True,
            "cycle_count": 7,
            "instances": {
                "i-test-control": {
                    "status_after": "Running",
                    "traffic_gb": 46.22,
                }
            },
        }
        status = telegram_control.build_status_text(
            guard, config=self.config, state=state
        )
        instances = telegram_control.build_instances_text(
            guard, config=self.config, state=state
        )
        self.assertIn("检测次数: 7", status)
        self.assertIn("46.22 GB / 180.00 GB", instances)
        self.assertNotIn("test-ak", status + instances)
        self.assertNotIn("test-sk", status + instances)

    def test_unauthorized_user_is_rejected(self):
        with mock.patch.object(self.service, "_send") as send:
            self.service._handle_message(
                self.config,
                self.telegram,
                {123},
                private_message("/status", user_id=999),
            )
        self.assertIn("无权限", send.call_args.args[2])
        self.assertFalse(self.service.pending)

    def test_check_command_requires_confirmation(self):
        with mock.patch.object(self.service, "_send"), mock.patch.object(
            guard, "load_config", return_value=self.config
        ):
            self.service._handle_message(
                self.config,
                self.telegram,
                {123},
                private_message("/check"),
            )
        self.assertEqual(len(self.service.pending), 1)
        pending = next(iter(self.service.pending.values()))
        self.assertEqual(pending["action"], "check")

    def test_button_navigation_edits_original_message_without_sending(self):
        with mock.patch.object(self.service, "_answer_callback"), mock.patch.object(
            self.service, "_telegram_api", return_value=True
        ) as api, mock.patch.object(self.service, "_send") as send:
            self.service._handle_callback(
                self.config,
                self.telegram,
                {123},
                button_callback("ag:instances", message_id=77),
            )
        send.assert_not_called()
        api.assert_called_once()
        method = api.call_args.args[1]
        data = api.call_args.args[2]
        self.assertEqual(method, "editMessageText")
        self.assertEqual(data["chat_id"], "123")
        self.assertEqual(data["message_id"], "77")
        self.assertIn("监控实例", data["text"])
        self.assertIn("返回主菜单", data["reply_markup"])

    def test_check_confirmation_and_result_keep_original_message(self):
        with mock.patch.object(self.service, "_answer_callback"), mock.patch.object(
            self.service, "_telegram_api", return_value=True
        ) as api, mock.patch.object(self.service, "_send") as send:
            self.service._handle_callback(
                self.config,
                self.telegram,
                {123},
                button_callback("ag:req:check", message_id=79),
            )
        send.assert_not_called()
        token, pending = next(iter(self.service.pending.items()))
        self.assertEqual(pending["message_id"], 79)
        self.assertEqual(api.call_args.args[1], "editMessageText")

        with mock.patch.object(self.service, "_answer_callback"), mock.patch.object(
            self.service, "_telegram_api", return_value=True
        ) as api, mock.patch.object(self.service, "_send") as send, mock.patch.object(
            guard, "cycle_lock", return_value=contextlib.nullcontext(True)
        ), mock.patch.object(
            guard, "run_cycle", return_value=0
        ), mock.patch.object(
            guard, "load_state", return_value={"last_summary": "检测完成"}
        ):
            self.service._handle_callback(
                self.config,
                self.telegram,
                {123},
                button_callback("ag:confirm:{}".format(token), message_id=79),
            )
        send.assert_not_called()
        self.assertGreaterEqual(api.call_count, 2)
        for call in api.call_args_list:
            self.assertEqual(call.args[1], "editMessageText")
            self.assertEqual(call.args[2]["message_id"], "79")
        self.assertIn("检测完成", api.call_args.args[2]["text"])

    def test_leaving_confirmation_page_invalidates_pending_action(self):
        with mock.patch.object(self.service, "_send"), mock.patch.object(
            guard, "load_config", return_value=self.config
        ):
            self.service._handle_message(
                self.config,
                self.telegram,
                {123},
                private_message("/poweroff 1"),
            )
        self.assertTrue(self.service.pending)
        with mock.patch.object(self.service, "_answer_callback"), mock.patch.object(
            self.service, "_telegram_api", return_value=True
        ):
            self.service._handle_callback(
                self.config,
                self.telegram,
                {123},
                button_callback("ag:menu", message_id=80),
            )
        self.assertFalse(self.service.pending)

    def test_schedule_menu_is_part_of_single_message_panel(self):
        markup = self.service._menu_markup()
        serialized = str(markup)
        self.assertIn("定时计划", serialized)
        self.assertIn("ag:schedule", serialized)
        self.assertIn("/schedule", self.service._main_text())

    def test_main_menu_has_icons_and_close_button(self):
        serialized = str(self.service._menu_markup())
        for icon in ("📊", "🖥", "🔍", "▶", "⏹", "🕒", "✖"):
            self.assertIn(icon, serialized)
        self.assertIn("关闭菜单", serialized)
        self.assertIn("ag:close", serialized)

    def test_close_button_deletes_original_menu_message(self):
        with mock.patch.object(self.service, "_answer_callback") as answer, mock.patch.object(
            self.service, "_telegram_api", return_value=True
        ) as api:
            self.service._handle_callback(
                self.config,
                self.telegram,
                {123},
                button_callback("ag:close", message_id=81),
            )
        answer.assert_called_once_with(self.telegram, "callback-1", "菜单已关闭")
        api.assert_called_once_with(
            self.telegram,
            "deleteMessage",
            {"chat_id": "123", "message_id": "81"},
        )

    def test_close_button_falls_back_to_collapsed_message(self):
        calls = []

        def telegram_api(_telegram, method, data):
            calls.append((method, data))
            if method == "deleteMessage":
                raise RuntimeError("message is too old")
            return True

        with mock.patch.object(self.service, "_answer_callback"), mock.patch.object(
            self.service, "_telegram_api", side_effect=telegram_api
        ):
            self.service._handle_callback(
                self.config,
                self.telegram,
                {123},
                button_callback("ag:close", message_id=82),
            )
        self.assertEqual([item[0] for item in calls], ["deleteMessage", "editMessageText"])
        self.assertIn("菜单已关闭", calls[-1][1]["text"])
        self.assertIn('"inline_keyboard": []', calls[-1][1]["reply_markup"])

    def test_schedule_detail_and_back_navigation_edit_original_message(self):
        with mock.patch.object(self.service, "_answer_callback"), mock.patch.object(
            self.service, "_telegram_api", return_value=True
        ) as api, mock.patch.object(self.service, "_send") as send:
            self.service._handle_callback(
                self.config,
                self.telegram,
                {123},
                button_callback("ag:sched:view:0", message_id=88),
            )
        send.assert_not_called()
        data = api.call_args.args[2]
        self.assertEqual(api.call_args.args[1], "editMessageText")
        self.assertEqual(data["message_id"], "88")
        self.assertIn("定时开关机", data["text"])
        self.assertIn("修改时间", data["reply_markup"])
        self.assertIn("返回实例列表", data["reply_markup"])

    def test_schedule_toggle_saves_and_updates_same_message(self):
        config = make_config()
        with mock.patch.object(self.service, "_answer_callback"), mock.patch.object(
            self.service, "_telegram_api", return_value=True
        ) as api, mock.patch.object(
            guard, "cycle_lock", return_value=contextlib.nullcontext(True)
        ), mock.patch.object(
            guard, "load_config", return_value=config
        ), mock.patch.object(
            guard, "atomic_write_json"
        ) as write:
            self.service._handle_callback(
                config,
                config["telegram"],
                {123},
                button_callback("ag:sched:set:0:1", message_id=91),
            )
        self.assertTrue(config["users"][0]["schedule"]["enabled"])
        write.assert_called_once_with(guard.CONFIG_FILE, config, mode=0o600)
        data = api.call_args.args[2]
        self.assertEqual(api.call_args.args[1], "editMessageText")
        self.assertEqual(data["message_id"], "91")
        self.assertIn("计划状态: 已启用", data["text"])

    def test_schedule_time_input_updates_original_panel_message(self):
        config = make_config()
        with mock.patch.object(self.service, "_answer_callback"), mock.patch.object(
            self.service, "_telegram_api", return_value=True
        ):
            self.service._handle_callback(
                config,
                config["telegram"],
                {123},
                button_callback("ag:sched:edit:0", message_id=92),
            )
        self.assertIn(123, self.service.schedule_inputs)
        with mock.patch.object(
            self.service, "_telegram_api", return_value=True
        ) as api, mock.patch.object(
            guard, "cycle_lock", return_value=contextlib.nullcontext(True)
        ), mock.patch.object(
            guard, "load_config", return_value=config
        ), mock.patch.object(
            guard, "atomic_write_json"
        ) as write:
            self.service._handle_message(
                config,
                config["telegram"],
                {123},
                private_message("22:30 06:15"),
            )
        self.assertEqual(
            config["users"][0]["schedule"],
            {"enabled": False, "start_time": "22:30", "stop_time": "06:15"},
        )
        self.assertNotIn(123, self.service.schedule_inputs)
        write.assert_called_once_with(guard.CONFIG_FILE, config, mode=0o600)
        data = api.call_args.args[2]
        self.assertEqual(api.call_args.args[1], "editMessageText")
        self.assertEqual(data["message_id"], "92")
        self.assertIn("每日开机: 22:30", data["text"])

    def test_invalid_schedule_time_keeps_input_open_on_same_message(self):
        config = make_config()
        with mock.patch.object(self.service, "_answer_callback"), mock.patch.object(
            self.service, "_telegram_api", return_value=True
        ):
            self.service._handle_callback(
                config,
                config["telegram"],
                {123},
                button_callback("ag:sched:edit:0", message_id=93),
            )
        with mock.patch.object(
            self.service, "_telegram_api", return_value=True
        ) as api, mock.patch.object(guard, "atomic_write_json") as write:
            self.service._handle_message(
                config,
                config["telegram"],
                {123},
                private_message("08:00 08:00"),
            )
        self.assertIn(123, self.service.schedule_inputs)
        write.assert_not_called()
        data = api.call_args.args[2]
        self.assertEqual(data["message_id"], "93")
        self.assertIn("不能相同", data["text"])

    def test_stopped_instance_needs_two_confirmations_and_threshold_override(self):
        with mock.patch.object(self.service, "_send"), mock.patch.object(
            guard, "load_config", return_value=self.config
        ):
            self.service._handle_message(
                self.config,
                self.telegram,
                {123},
                private_message("/poweron 1"),
            )
        first_token, first = next(iter(self.service.pending.items()))
        self.assertEqual(first["stage"], 1)

        with mock.patch.object(self.service, "_send"), mock.patch.object(
            self.service, "_answer_callback"
        ), mock.patch.object(
            guard, "cycle_lock", return_value=contextlib.nullcontext(True)
        ), mock.patch.object(
            guard, "load_config", return_value=self.config
        ), mock.patch.object(
            guard, "query_instance_status", return_value="Stopped"
        ), mock.patch.object(
            guard, "query_cdt_traffic_gb", return_value=200.0
        ), mock.patch.object(web_panel, "control_instance") as control:
            self.service._handle_callback(
                self.config,
                self.telegram,
                {123},
                callback(first_token),
            )
        control.assert_not_called()
        self.assertEqual(len(self.service.pending), 1)
        second_token, second = next(iter(self.service.pending.items()))
        self.assertEqual(second["stage"], 2)
        self.assertTrue(second["threshold_override"])

        result = {
            "message": "Telegram Bot 手动开机完成",
            "threshold_overridden": True,
            "monitor_paused": True,
        }
        with mock.patch.object(self.service, "_send"), mock.patch.object(
            self.service, "_answer_callback"
        ), mock.patch.object(
            guard, "load_config", return_value=self.config
        ), mock.patch.object(
            web_panel, "control_instance", return_value=result
        ) as control:
            second_callback = callback(second_token, callback_id="callback-2")
            self.service._handle_callback(
                self.config, self.telegram, {123}, second_callback
            )
            self.service._handle_callback(
                self.config, self.telegram, {123}, second_callback
            )
        control.assert_called_once_with(
            guard,
            0,
            "start",
            source="Telegram Bot",
            notify=False,
            allow_threshold_override=True,
            pause_on_threshold_override=True,
        )
        self.assertFalse(self.service.pending)

    def test_safe_stopped_instance_still_needs_second_confirmation(self):
        with mock.patch.object(self.service, "_send"), mock.patch.object(
            guard, "load_config", return_value=self.config
        ):
            self.service._handle_message(
                self.config,
                self.telegram,
                {123},
                private_message("/poweron i-test-control"),
            )
        first_token = next(iter(self.service.pending))
        with mock.patch.object(self.service, "_send"), mock.patch.object(
            self.service, "_answer_callback"
        ), mock.patch.object(
            guard, "cycle_lock", return_value=contextlib.nullcontext(True)
        ), mock.patch.object(
            guard, "load_config", return_value=self.config
        ), mock.patch.object(
            guard, "query_instance_status", return_value="Stopped"
        ), mock.patch.object(
            guard, "query_cdt_traffic_gb", return_value=10.0
        ):
            self.service._handle_callback(
                self.config, self.telegram, {123}, callback(first_token)
            )
        second = next(iter(self.service.pending.values()))
        self.assertEqual(second["stage"], 2)
        self.assertFalse(second["threshold_override"])

    def test_other_admin_cannot_consume_confirmation(self):
        with mock.patch.object(self.service, "_send"), mock.patch.object(
            guard, "load_config", return_value=self.config
        ):
            self.service._handle_message(
                self.config,
                self.telegram,
                {123, 456},
                private_message("/poweroff 1"),
            )
        token = next(iter(self.service.pending))
        with mock.patch.object(self.service, "_answer_callback") as answer:
            self.service._handle_callback(
                self.config,
                self.telegram,
                {123, 456},
                callback(token, user_id=456),
            )
        self.assertIn(token, self.service.pending)
        self.assertTrue(answer.call_args.kwargs["alert"])

    def test_prepare_token_discards_old_updates_without_processing(self):
        old_update = {
            "update_id": 41,
            "message": private_message("/poweroff 1"),
        }
        with mock.patch.object(
            self.service,
            "_telegram_api",
            side_effect=[[old_update], True],
        ) as api, mock.patch.object(
            telegram_control, "_save_offset"
        ) as save, mock.patch.object(
            self.service, "_handle_update"
        ) as handle:
            self.service._prepare_token(self.telegram)
        self.assertEqual(api.call_args_list[0].args[1], "getUpdates")
        self.assertEqual(api.call_args_list[0].args[2]["offset"], -1)
        self.assertEqual(self.service.offset, 42)
        save.assert_called_once_with(
            guard, self.service.fingerprint, 42
        )
        handle.assert_not_called()


if __name__ == "__main__":
    unittest.main()
