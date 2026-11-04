import json, os, unittest
from dataset import casos_relatorio
from lojinha.relatorio import gerar_relatorio

GOLD = json.load(open(os.path.join(os.path.dirname(__file__), "goldens.json")))


class TestRelatorioOculto(unittest.TestCase):
    def test_goldens(self):
        for nome, ps, fmt in casos_relatorio():
            with self.subTest(nome):
                self.assertEqual(gerar_relatorio(ps, fmt), GOLD[nome])

    def test_erros(self):
        for fmt in ["xml", "XML", "", "pdf "]:
            with self.subTest(fmt):
                with self.assertRaises(ValueError) as cm:
                    gerar_relatorio([], fmt)
                self.assertEqual("ValueError: " + str(cm.exception), GOLD["erro-" + fmt])
