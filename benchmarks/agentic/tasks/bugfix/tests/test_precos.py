import unittest
from decimal import Decimal

from lojinha.cupons import buscar_cupom
from lojinha.models import Item, Pedido
from lojinha.precos import frete, subtotal, total


def pedido(valor, uf="SP", cupom=None, qtd=1):
    return Pedido(1, "Ana", uf, [Item("A1", "Caneca", Decimal(valor), qtd)], cupom)


class TestPrecos(unittest.TestCase):
    def test_subtotal(self):
        self.assertEqual(subtotal(pedido("12.50", qtd=3)), Decimal("37.50"))

    def test_frete_sp_e_outras(self):
        self.assertEqual(frete(pedido("50.00", "SP")), Decimal("15.00"))
        self.assertEqual(frete(pedido("50.00", "MG")), Decimal("25.00"))

    def test_frete_gratis_por_valor(self):
        self.assertEqual(frete(pedido("250.00", "RJ")), Decimal("0"))

    def test_frete_gratis_por_cupom(self):
        self.assertEqual(frete(pedido("10.00", "RJ", "FRETEGRATIS")), Decimal("0"))

    def test_total_sem_cupom(self):
        self.assertEqual(total(pedido("50.00", "SP")), Decimal("65.00"))

    def test_cupom_desconhecido(self):
        with self.assertRaises(ValueError):
            buscar_cupom("BLACKFRIDAY")

    def test_quantidade_invalida(self):
        with self.assertRaises(ValueError):
            Item("A1", "Caneca", Decimal("1.00"), 0)


if __name__ == "__main__":
    unittest.main()
