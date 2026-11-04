import unittest
from decimal import Decimal

from lojinha.models import Item, Pedido
from lojinha.relatorio import gerar_relatorio


class TestRelatorio(unittest.TestCase):
    def setUp(self):
        self.pedidos = [Pedido(7, "Bruno", "SP", [Item("A1", "Caneca", Decimal("50.00"), 2)])]

    def test_csv(self):
        self.assertEqual(
            gerar_relatorio(self.pedidos, "csv"),
            "id,cliente,itens,subtotal,desconto,frete,total\n"
            "7,Bruno,2,100.00,0.00,15.00,115.00\n"
            "TOTAL,,2,100.00,0.00,15.00,115.00\n",
        )

    def test_md_vazio(self):
        self.assertEqual(gerar_relatorio([], "md"), "_Nenhum pedido._\n")

    def test_formato_invalido(self):
        with self.assertRaises(ValueError):
            gerar_relatorio(self.pedidos, "xml")


if __name__ == "__main__":
    unittest.main()
