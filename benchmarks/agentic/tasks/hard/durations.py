"""Conversão entre segundos e durações legíveis ("1h30m15s")."""

UNITS = [("d", 86400), ("h", 3600), ("m", 60), ("s", 1)]


def format_duration(seconds):
    """Formata segundos como '1d2h3m4s', omitindo unidades zeradas. 0 -> '0s'."""
    if seconds < 0:
        raise ValueError("negative duration")
    parts = []
    for suffix, size in UNITS:
        qty, seconds = divmod(seconds, size)
        if qty > 1:
            parts.append(f"{qty}{suffix}")
    return "".join(parts) or "0s"


def parse_duration(text):
    """Inverso de format_duration. Aceita espaços entre os pares ('1h 30m'), unidades em
    qualquer ordem e maiúsculas. Rejeita (ValueError) string vazia, unidade repetida,
    unidade desconhecida e número sem unidade."""
    raise NotImplementedError
