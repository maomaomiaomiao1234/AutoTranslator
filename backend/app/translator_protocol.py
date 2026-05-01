from typing import Iterator, Protocol, runtime_checkable


@runtime_checkable
class Translator(Protocol):
    """翻译器统一接口。"""

    def translate(self, text: str) -> str:
        """同步翻译，返回译文。"""
        ...

    def translate_stream(self, text: str) -> Iterator[str]:
        """流式翻译，逐 token yield 译文片段。可选实现。"""
        ...
