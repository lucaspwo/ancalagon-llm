"""Cálculo de preço de pedidos.

Regras de negócio:
- subtotal = soma de preco * qtd dos itens.
- Cupom percentual incide só sobre o subtotal, nunca sobre o frete.
- Frete grátis quando o subtotal (antes do desconto) é de R$ 200,00 ou mais,
  ou quando o cupom é de frete grátis. Caso contrário: SP = R$ 15,00, demais UFs = R$ 25,00.
- Valores monetários finais são arredondados para 2 casas, meio para cima (0,005 -> 0,01).
"""

from decimal import ROUND_HALF_UP, Decimal

from .cupons import buscar_cupom

FRETE_GRATIS_A_PARTIR_DE = Decimal("200.00")
FRETE_SP = Decimal("15.00")
FRETE_OUTRAS_UFS = Decimal("25.00")
CENTAVO = Decimal("0.01")


def arredondar(valor):
    return valor.quantize(CENTAVO, rounding=ROUND_HALF_UP)


def subtotal(pedido):
    return sum((it.preco * it.qtd for it in pedido.itens), Decimal("0"))


def desconto(pedido):
    cupom = buscar_cupom(pedido.cupom)
    if cupom is None or cupom[0] != "pct":
        return Decimal("0")
    return subtotal(pedido) * cupom[1]


def frete(pedido):
    cupom = buscar_cupom(pedido.cupom)
    if cupom is not None and cupom[0] == "frete":
        return Decimal("0")
    if subtotal(pedido) >= FRETE_GRATIS_A_PARTIR_DE:
        return Decimal("0")
    return FRETE_SP if pedido.uf.upper() == "SP" else FRETE_OUTRAS_UFS


def total(pedido):
    return arredondar(subtotal(pedido) - desconto(pedido) + frete(pedido))
