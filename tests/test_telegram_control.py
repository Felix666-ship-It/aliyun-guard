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
    return {
        "id": callback_id,
        "from": {"id": user_id},
        "message": {
            "message_id": 10,
            "chat": {"id": user_id, "type": "private"},
        },
        "data": "ag:confirm:{}".format(token),
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
        ), mock.patch.object(self.service, "_remove_buttons"), mock.patch.object(
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
        ), mock.patch.object(self.service, "_remove_buttons"), mock.patch.object(
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
        ), mock.patch.object(self.service, "_remove_buttons"), mock.patch.object(
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
