"""Modelos de domínio da lojinha."""

from dataclasses import dataclass, field
from decimal import Decimal


@dataclass(frozen=True)
class Item:
    sku: str
    nome: str
    preco: Decimal
    qtd: int = 1

    def __post_init__(self):
        if self.qtd < 1:
            raise ValueError(f"quantidade inválida para {self.sku}: {self.qtd}")
        if self.preco < 0:
            raise ValueError(f"preço negativo para {self.sku}: {self.preco}")


@dataclass
class Pedido:
    id: int
    cliente: str
    uf: str
    itens: list = field(default_factory=list)
    cupom: str | None = None
