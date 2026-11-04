import json, sys
sys.path.insert(0, sys.argv[1]); sys.path.insert(0, sys.argv[2])
from dataset import casos_relatorio
from lojinha.relatorio import gerar_relatorio
out = {nome: gerar_relatorio(ps, fmt) for nome, ps, fmt in casos_relatorio()}
for fmt in ["xml", "XML", "", "pdf "]:
    try:
        gerar_relatorio([], fmt); out["erro-" + fmt] = None
    except ValueError as e:
        out["erro-" + fmt] = "ValueError: " + str(e)
json.dump(out, open(sys.argv[3], "w"), ensure_ascii=False, indent=1)
print(len(out), "goldens")
