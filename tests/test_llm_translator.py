#!/usr/bin/env python3
"""Tests for LLMTranslator.

Set DEEPSEEK_API_KEY or LLM_API_KEY to run integration tests; skipped otherwise.
"""

import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from backend.LLM_set.main import LLMTranslator

API_KEY = os.environ.get("DEEPSEEK_API_KEY") or os.environ.get("LLM_API_KEY")
NEEDS_KEY = pytest.mark.skipif(not API_KEY, reason="未设置 DEEPSEEK_API_KEY / LLM_API_KEY")


class TestInit:
    def test_missing_api_key_raises(self):
        with pytest.raises(ValueError, match="API Key"):
            LLMTranslator(api_key="")  # empty string bypasses env vars

    def test_explicit_api_key(self):
        t = LLMTranslator(api_key="sk-test")
        assert t.source == "auto"
        assert t.target == "zh-CN"

    def test_custom_model_and_url(self):
        t = LLMTranslator(api_key="sk-test", model="deepseek-r1",
                          base_url="https://custom.api/v1")
        assert t.model == "deepseek-r1"


class TestTranslate:
    @NEEDS_KEY
    def test_basic_translate_en_to_zh(self):
        t = LLMTranslator(source="en", target="zh-CN")
        result = t.translate("Hello world")
        assert result
        assert isinstance(result, str)
        assert len(result) > 0

    @NEEDS_KEY
    def test_auto_detect_source(self):
        t = LLMTranslator(source="auto", target="en")
        result = t.translate("你好世界")
        assert result
        assert isinstance(result, str)

    @NEEDS_KEY
    def test_same_target_no_change(self):
        t = LLMTranslator(source="zh-CN", target="zh-CN")
        result = t.translate("你好")
        assert result
        assert isinstance(result, str)

    @NEEDS_KEY
    def test_japanese_to_chinese(self):
        t = LLMTranslator(source="ja", target="zh-CN")
        result = t.translate("こんにちは世界")
        assert result
        assert isinstance(result, str)
