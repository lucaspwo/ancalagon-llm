"""Relatório de pedidos em CSV, JSON ou Markdown."""

import json
from decimal import ROUND_HALF_UP, Decimal

from .cupons import buscar_cupom


def gerar_relatorio(pedidos, formato="csv"):
    formato = formato.lower()
    pedidos = sorted(pedidos, key=lambda p: p.id)
    if formato == "csv":
        linhas = ["id,cliente,itens,subtotal,desconto,frete,total"]
        soma_itens = 0
        soma_sub = Decimal("0")
        soma_desc = Decimal("0")
        soma_frete = Decimal("0")
        soma_total = Decimal("0")
        for p in pedidos:
            sub = Decimal("0")
            n = 0
            for it in p.itens:
                sub += it.preco * it.qtd
                n += it.qtd
            cupom = buscar_cupom(p.cupom)
            if cupom is not None and cupom[0] == "pct":
                desc = sub * cupom[1]
            else:
                desc = Decimal("0")
            if cupom is not None and cupom[0] == "frete":
                fr = Decimal("0")
            elif sub >= Decimal("200.00"):
                fr = Decimal("0")
            elif p.uf.upper() == "SP":
                fr = Decimal("15.00")
            else:
                fr = Decimal("25.00")
            tot = (sub - desc + fr).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
            sub_r = sub.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
            desc_r = desc.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
            fr_r = fr.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
            cliente = p.cliente.strip()
            if "," in cliente or '"' in cliente:
                cliente = '"' + cliente.replace('"', '""') + '"'
            linhas.append(f"{p.id},{cliente},{n},{sub_r},{desc_r},{fr_r},{tot}")
            soma_itens += n
            soma_sub += sub_r
            soma_desc += desc_r
            soma_frete += fr_r
            soma_total += tot
        linhas.append(f"TOTAL,,{soma_itens},{soma_sub},{soma_desc},{soma_frete},{soma_total}")
        return "\n".join(linhas) + "\n"
    elif formato == "json":
        saida = []
        soma_total = Decimal("0")
        for p in pedidos:
            sub = Decimal("0")
            n = 0
            for it in p.itens:
                sub += it.preco * it.qtd
                n += it.qtd
            cupom = buscar_cupom(p.cupom)
            if cupom is not None and cupom[0] == "pct":
                desc = sub * cupom[1]
            else:
                desc = Decimal("0")
            if cupom is not None and cupom[0] == "frete":
                fr = Decimal("0")
            elif sub >= Decimal("200.00"):
                fr = Decimal("0")
            elif p.uf.upper() == "SP":
                fr = Decimal("15.00")
            else:
                fr = Decimal("25.00")
            tot = (sub - desc + fr).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
            saida.append({
                "id": p.id,
                "cliente": p.cliente.strip(),
                "itens": n,
                "subtotal": str(sub.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)),
                "desconto": str(desc.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)),
                "frete": str(fr.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)),
                "total": str(tot),
                "cupom": p.cupom.strip().upper() if p.cupom and p.cupom.strip() else None,
            })
            soma_total += tot
        return json.dumps(
            {"pedidos": saida, "resumo": {"quantidade": len(saida), "total": str(soma_total)}},
            ensure_ascii=False,
            indent=2,
        )
    elif formato == "md":
        if not pedidos:
            return "_Nenhum pedido._\n"
        linhas = ["| Pedido | Cliente | Itens | Total |", "|---:|---|---:|---:|"]
        soma_total = Decimal("0")
        for p in pedidos:
            sub = Decimal("0")
            n = 0
            for it in p.itens:
                sub += it.preco * it.qtd
                n += it.qtd
            cupom = buscar_cupom(p.cupom)
            if cupom is not None and cupom[0] == "pct":
                desc = sub * cupom[1]
            else:
                desc = Decimal("0")
            if cupom is not None and cupom[0] == "frete":
                fr = Decimal("0")
            elif sub >= Decimal("200.00"):
                fr = Decimal("0")
            elif p.uf.upper() == "SP":
                fr = Decimal("15.00")
            else:
                fr = Decimal("25.00")
            tot = (sub - desc + fr).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
            valor = f"{tot:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")
            cliente = p.cliente.strip().replace("|", "\\|")
            linhas.append(f"| #{p.id} | {cliente} | {n} | R$ {valor} |")
            soma_total += tot
        valor = f"{soma_total:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")
        plural = "pedido" if len(pedidos) == 1 else "pedidos"
        linhas.append("")
        linhas.append(f"**Total geral: R$ {valor}** ({len(pedidos)} {plural})")
        return "\n".join(linhas) + "\n"
    else:
        raise ValueError(f"formato desconhecido: {formato}")
