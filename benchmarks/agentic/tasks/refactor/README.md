# lojinha

Pedidos, preços, cupons e relatórios de uma loja pequena. Só biblioteca padrão (Python 3.12+).

    python3 -m unittest discover -s tests -t .

- `lojinha/models.py` — `Item`, `Pedido`
- `lojinha/cupons.py` — tabela de cupons e `buscar_cupom`
- `lojinha/precos.py` — `subtotal`, `desconto`, `frete`, `total` (regras de negócio no docstring)
- `lojinha/relatorio.py` — `gerar_relatorio(pedidos, formato)` em csv/json/md
