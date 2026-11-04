from durations import parse_duration


def total(texts):
    """Soma uma lista de durações em texto, ignorando entradas vazias ou só com espaços."""
    return sum(parse_duration(t) for t in texts if t)
