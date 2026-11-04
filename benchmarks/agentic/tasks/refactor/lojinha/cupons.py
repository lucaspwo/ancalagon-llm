"""Cupons de desconto.

Regras:
- O código do cupom não diferencia maiúsculas de minúsculas ("dezoff" == "DEZOFF")
  e ignora espaços nas pontas.
- Cupom desconhecido é erro (ValueError), não é ignorado em silêncio.
"""

from decimal import Decimal

# código -> (tipo, valor). tipo "pct" = percentual sobre o subtotal; "frete" = frete grátis.
CUPONS = {
    "DEZOFF": ("pct", Decimal("0.10")),
    "VINTEOFF": ("pct", Decimal("0.20")),
    "FRETEGRATIS": ("frete", None),
}


def buscar_cupom(codigo):
    """Retorna (tipo, valor) do cupom, ou None se codigo for None/vazio."""
    if codigo is None or not codigo.strip():
        return None
    chave = codigo.strip().upper()
    if chave not in CUPONS:
        raise ValueError(f"cupom desconhecido: {codigo!r}")
    return CUPONS[chave]
