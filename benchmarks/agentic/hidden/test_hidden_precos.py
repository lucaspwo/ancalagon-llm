import unittest
from decimal import Decimal as D

from lojinha.cupons import buscar_cupom
from lojinha.models import Item, Pedido
from lojinha.precos import desconto, frete, subtotal, total


def ped(valor, uf="SP", cupom=None, qtd=1):
    return Pedido(1, "X", uf, [Item("A", "a", D(valor), qtd)], cupom)


class TestPrecosOculto(unittest.TestCase):
    # issue item 1: cupom case-insensitive
    def test_cupom_minusculo(self):
        self.assertEqual(buscar_cupom("dezoff"), buscar_cupom("DEZOFF"))
        self.assertEqual(buscar_cupom("  fretegratis "), ("frete", None))
        self.assertEqual(total(ped("100.00", "RJ", "dezoff")), D("115.00"))

    def test_cupom_vazio_e_desconhecido(self):
        self.assertIsNone(buscar_cupom(None))
        self.assertIsNone(buscar_cupom("   "))
        with self.assertRaises(ValueError):
            buscar_cupom("nada")

    # issue item 2: limite de frete grátis inclusivo
    def test_frete_limite(self):
        self.assertEqual(frete(ped("200.00", "RJ")), D("0"))
        self.assertEqual(frete(ped("100.00", "RJ", qtd=2)), D("0"))
        self.assertEqual(frete(ped("199.99", "RJ")), D("25.00"))
        self.assertEqual(frete(ped("199.99", "sp")), D("15.00"))

    def test_frete_usa_subtotal_antes_do_desconto(self):
        self.assertEqual(frete(ped("210.00", "RJ", "VINTEOFF")), D("0"))
        self.assertEqual(total(ped("210.00", "RJ", "VINTEOFF")), D("168.00"))

    # issue item 3: desconto só sobre produtos
    def test_desconto_nao_incide_no_frete(self):
        self.assertEqual(desconto(ped("100.00", "RJ", "DEZOFF")), D("10.00"))
        self.assertEqual(total(ped("100.00", "RJ", "DEZOFF")), D("115.00"))
        self.assertEqual(total(ped("50.00", "SP", "VINTEOFF")), D("55.00"))

    # issue item 4: arredondamento meio para cima
    def test_arredondamento(self):
        self.assertEqual(total(ped("10.05", "RJ", "DEZOFF")), D("34.05"))
        self.assertEqual(total(ped("0.125", "SP")), D("15.13"))
        self.assertEqual(total(ped("0.135", "SP")), D("15.14"))

    def test_sem_regressao(self):
        self.assertEqual(subtotal(ped("12.50", qtd=3)), D("37.50"))
        self.assertEqual(total(ped("50.00", "SP")), D("65.00"))
        self.assertEqual(total(ped("10.00", "RJ", "FRETEGRATIS")), D("10.00"))
        self.assertEqual(total(ped("1000.00", "RJ", "DEZOFF")), D("900.00"))
