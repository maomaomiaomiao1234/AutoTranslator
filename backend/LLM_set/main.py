#!/usr/bin/env python3
"""LLM-based translator using DeepSeek API (OpenAI SDK)."""

import logging
import os

from openai import OpenAI

logger = logging.getLogger(__name__)

LANG_NAMES = {
    "auto": "自动检测",
    "zh-CN": "中文简体",
    "en": "英语",
    "ja": "日语",
    "ko": "韩语",
    "fr": "法语",
    "de": "德语",
    "ru": "俄语",
}


class LLMTranslator:
    """Translation via LLM API, matching the interface of deep_translator.GoogleTranslator.

    Usage::

        t = LLMTranslator(source="auto", target="zh-CN")
        result = t.translate("Hello world")
    """

    def __init__(self, source="auto", target="zh-CN",
                 api_key=None, model="deepseek-v3.2",
		 base_url="https://dashscope.aliyuncs.com/compatible-mode/v1",
                 #base_url="https://api.deepseek.com/v1"
		):
        self.source = source
        self.target = target
        self.model = model

        api_key = api_key or os.environ.get("DEEPSEEK_API_KEY") or os.environ.get("LLM_API_KEY")
        if not api_key:
            raise ValueError(
                "未设置 API Key。请通过参数 api_key 传入，"
                "或设置环境变量 DEEPSEEK_API_KEY / LLM_API_KEY"
            )

        self._client = OpenAI(api_key=api_key, base_url=base_url)

    def _build_instruction(self):
        src_name = LANG_NAMES.get(self.source, self.source)
        tgt_name = LANG_NAMES.get(self.target, self.target)

        if self.source == "auto":
            return f"将以下文本翻译为{tgt_name}。如果原文已是{tgt_name}则原样返回。只输出译文，不要任何解释或额外文字，疑问句也正常翻译。"
        else:
            return f"将以下{src_name}文本翻译为{tgt_name}。只输出译文，不要任何解释或额外文字，疑问句也正常翻译。"

    def translate(self, text):
        instruction = self._build_instruction()

        try:
            resp = self._client.chat.completions.create(
                model=self.model,
                messages=[
                    {"role": "system", "content": instruction},
                    {"role": "user", "content": text},
                ],
                temperature=0.3,
                max_tokens=4096,
                extra_body={"enable_thinking": False},
            )
        except Exception as e:
            logger.error("LLM API 请求失败: %s", e)
            raise RuntimeError(f"LLM API 请求失败: {e}")

        return resp.choices[0].message.content.strip()

    def translate_stream(self, text):
        """流式翻译，逐 token yield 译文片段。"""
        instruction = self._build_instruction()

        try:
            resp = self._client.chat.completions.create(
                model=self.model,
                messages=[
                    {"role": "system", "content": instruction},
                    {"role": "user", "content": text},
                ],
                temperature=0.3,
                max_tokens=4096,
                extra_body={"enable_thinking": False},
                stream=True,
            )
        except Exception as e:
            logger.error("LLM API 请求失败: %s", e)
            raise RuntimeError(f"LLM API 请求失败: {e}")

        for chunk in resp:
            token = chunk.choices[0].delta.content
            if token:
                yield token
