"""Dataset fixo para os testes ocultos (o modelo nunca vê este arquivo)."""
from decimal import Decimal as D

from lojinha.models import Item, Pedido


def pedidos():
    return [
        Pedido(30, "  Zé da Silva ", "rj", [Item("B2", "Prato", D("10.05"), 1)], "dezoff"),
        Pedido(4, 'Loja "Boa", Ltda', "SP", [Item("C3", "Copo", D("0.125"), 1)]),
        Pedido(12, "Ana|Maria", "MG", [Item("A1", "Caneca", D("100.00"), 2)], " VINTEOFF "),
        Pedido(1, "Ção Ñandú", "sp", [Item("A1", "Caneca", D("99.995"), 2), Item("D4", "Pires", D("0.01"), 3)]),
        Pedido(8, "Bruno", "BA", [Item("E5", "Jarra", D("1234.567"), 1)], "FreteGratis"),
        Pedido(19, "Carla", "SP", [Item("F6", "Bule", D("199.99"), 1)], ""),
        Pedido(2, "Duda", "PR", [Item("G7", "Tigela", D("200.00"), 1)], "DEZOFF"),
    ]


def casos_relatorio():
    """(nome, lista de pedidos, formato)."""
    todos = pedidos()
    casos = []
    for fmt in ["csv", "json", "md", "CSV", "Md"]:
        casos.append((f"todos-{fmt}", todos, fmt))
        casos.append((f"vazio-{fmt}", [], fmt))
        casos.append((f"um-{fmt}", [todos[5]], fmt))
    return casos
