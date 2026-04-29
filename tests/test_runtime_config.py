#!/usr/bin/env python3

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from backend.app.runtime_config import apply_runtime_config, load_runtime_config


class TestLoadRuntimeConfig:
    def test_returns_empty_for_missing_file(self, tmp_path):
        assert load_runtime_config(tmp_path / "missing.json") == {}

    def test_reads_supported_keys_only(self, tmp_path):
        config_path = tmp_path / "config.json"
        config_path.write_text(
            json.dumps(
                {
                    "TRANSLATOR_BACKEND": "llm",
                    "DEEPSEEK_API_KEY": "sk-test",
                    "LLM_API_KEY": "sk-llm",
                    "IGNORED": "value",
                }
            ),
            encoding="utf-8",
        )

        assert load_runtime_config(config_path) == {
            "TRANSLATOR_BACKEND": "llm",
            "DEEPSEEK_API_KEY": "sk-test",
            "LLM_API_KEY": "sk-llm",
        }


class TestApplyRuntimeConfig:
    def test_does_not_override_existing_env(self, tmp_path, monkeypatch):
        config_path = tmp_path / "config.json"
        config_path.write_text(
            json.dumps(
                {
                    "TRANSLATOR_BACKEND": "llm",
                    "DEEPSEEK_API_KEY": "sk-file",
                }
            ),
            encoding="utf-8",
        )

        monkeypatch.setenv("TRANSLATOR_BACKEND", "google")
        applied = apply_runtime_config(config_path)

        assert applied["TRANSLATOR_BACKEND"] == "llm"
        assert os.environ["TRANSLATOR_BACKEND"] == "google"
        assert os.environ["DEEPSEEK_API_KEY"] == "sk-file"
