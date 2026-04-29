#!/usr/bin/env python3
"""Runtime configuration helpers for packaged macOS builds."""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path


logger = logging.getLogger(__name__)

APP_NAME = "AutoTranslator"
APP_SUPPORT_DIR = Path.home() / "Library" / "Application Support" / APP_NAME
CONFIG_PATH = APP_SUPPORT_DIR / "config.json"
ENV_KEYS = ("TRANSLATOR_BACKEND", "DEEPSEEK_API_KEY", "LLM_API_KEY")


def load_runtime_config(config_path: Path = CONFIG_PATH) -> dict[str, str]:
    if not config_path.exists():
        return {}

    try:
        with config_path.open("r", encoding="utf-8") as fh:
            payload = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        logger.warning("读取配置文件失败: %s", exc)
        return {}

    if not isinstance(payload, dict):
        logger.warning("配置文件格式无效: %s", config_path)
        return {}

    result = {}
    for key in ENV_KEYS:
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            result[key] = value.strip()
    return result


def apply_runtime_config(config_path: Path = CONFIG_PATH) -> dict[str, str]:
    config = load_runtime_config(config_path)
    for key, value in config.items():
        os.environ.setdefault(key, value)
    return config
