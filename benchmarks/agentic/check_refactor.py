"""Checagens estruturais da refatoração (além dos testes ocultos de saída)."""
import importlib
import os
import sys

w = sys.argv[1]
sys.path.insert(0, w)
os.chdir(w)


def ler(p):
    return open(p, encoding="utf-8").read() if os.path.exists(p) else ""


rel, fmt = ler("lojinha/relatorio.py"), ler("lojinha/formatos.py")
codigo = rel + fmt
res = {
    "formatos_py": "sim" if fmt else "NAO",
    "calc_duplicado": codigo.count("it.preco * it.qtd") + codigo.count("Decimal(\"200"),
    "usa_precos": "sim" if "precos" in codigo else "NAO",
    "linhas": len(codigo.splitlines()),
}
try:
    m = importlib.import_module("lojinha.formatos")
    regs = [n for n, v in vars(m).items() if isinstance(v, dict) and {"csv", "json", "md"} <= set(v)]
    res["registro"] = regs[0] if regs else "NAO"
except Exception as e:  # o módulo pode nem existir ou não importar
    res["registro"] = f"erro:{type(e).__name__}"
print(" ".join(f"{k}={v}" for k, v in res.items()))
