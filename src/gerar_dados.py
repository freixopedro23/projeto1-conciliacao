"""
Gerador de dados sintéticos – Projeto 1: Conciliação de Pagamentos

Cria uma massa fictícia de outubro/2026 com:
  - base interna de transações (6.000 linhas)
  - extratos de liquidação de dois provedores fictícios (PagaJá e LiquidaPay),
    cada um com seu próprio layout
  - contrato de taxas e prazos
  - divergências plantadas de propósito (o gabarito fica em gabarito/)
  - armadilhas que parecem erro mas não são
  - um banco SQLite com tudo carregado como texto (tabelas raw_*)

Uso:
    python src/gerar_dados.py              # seed padrão (42)
    python src/gerar_dados.py --seed 7     # outra massa, com outros erros

Só usa a biblioteca padrão do Python.
"""

import argparse
import csv
import random
import sqlite3
from datetime import date, datetime, timedelta
from decimal import Decimal, ROUND_DOWN, ROUND_HALF_UP
from pathlib import Path

# --------------------------------------------------------------------------
# Parâmetros
# --------------------------------------------------------------------------
N_TRANSACOES = 6000
INICIO = datetime(2026, 10, 1)
FIM_MES = date(2026, 10, 31)
CENT = Decimal("0.01")

# Contrato: (provedor, metodo, tipo) -> (taxa_pct, taxa_fixa, prazo_dias)
CONTRATO = {
    ("PAGAJA", "PIX", "DEPOSITO"): (Decimal("0.70"), Decimal("0.00"), 0),
    ("PAGAJA", "PIX", "SAQUE"): (Decimal("0.00"), Decimal("1.20"), 0),
    ("PAGAJA", "CARTAO", "DEPOSITO"): (Decimal("2.79"), Decimal("0.30"), 2),
    ("LIQUIDAPAY", "PIX", "DEPOSITO"): (Decimal("0.60"), Decimal("0.10"), 1),
    ("LIQUIDAPAY", "PIX", "SAQUE"): (Decimal("0.00"), Decimal("1.50"), 0),
    ("LIQUIDAPAY", "CARTAO", "DEPOSITO"): (Decimal("2.49"), Decimal("0.00"), 2),
}
NOME_CONTRATO = {"PAGAJA": "PagaJá", "LIQUIDAPAY": "LiquidaPay"}

# Quantidade de erros plantados por categoria
N_ERROS = {
    "AUSENTE_NO_EXTRATO": 12,
    "AUSENTE_NO_INTERNO": 8,
    "DUPLICIDADE": 10,
    "VALOR_DIVERGENTE": 9,
    "STATUS_DIVERGENTE": 10,
    "ESTORNO_NAO_REGISTRADO": 7,
    "LIQUIDACAO_ATRASADA": 11,
}
# Incidente de taxa: LiquidaPay cobrou 3,49% em vez de 2,49% no cartão entre 15 e 18/10
TAXA_INCIDENTE = Decimal("3.49")
JANELA_INCIDENTE = (date(2026, 10, 15), date(2026, 10, 18))


# --------------------------------------------------------------------------
# Funções auxiliares
# --------------------------------------------------------------------------
def taxa_contrato(valor, provedor, metodo, tipo):
    pct, fixa, _ = CONTRATO[(provedor, metodo, tipo)]
    return (valor * pct / 100 + fixa).quantize(CENT, ROUND_HALF_UP)


def prazo(provedor, metodo, tipo):
    return CONTRATO[(provedor, metodo, tipo)][2]


def liquido(tipo_lanc, bruto, taxa):
    """Efeito no caixa da plataforma."""
    if tipo_lanc == "DEPOSITO":
        return bruto - taxa
    if tipo_lanc == "SAQUE":
        return -(bruto + taxa)
    return -bruto  # ESTORNO


def br_num(v):
    """1234.5 -> '1.234,50' (formato da PagaJá)."""
    s = f"{abs(v):,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")
    return ("-" if v < 0 else "") + s


def valor_aleatorio(rng, tipo):
    mediana = 120 if tipo == "DEPOSITO" else 350
    v = rng.lognormvariate(0, 0.9) * mediana
    v = max(10, min(v, 15000))
    return Decimal(str(v)).quantize(CENT, ROUND_HALF_UP)


def momento_aleatorio(rng, dia_min=1, dia_max=31):
    dia = rng.randint(dia_min, dia_max)
    # mais movimento à noite, como numa plataforma online
    hora = rng.choices(range(24), weights=[3, 2, 1, 1, 1, 1, 1, 2, 3, 4, 5, 5,
                                           6, 6, 6, 6, 6, 7, 8, 9, 10, 10, 9, 6])[0]
    return datetime(2026, 10, dia, hora, rng.randint(0, 59), rng.randint(0, 59))


# --------------------------------------------------------------------------
# Geração
# --------------------------------------------------------------------------
def gerar(seed, saida):
    rng = random.Random(seed)

    # ---- 1. Base interna ------------------------------------------------
    trans = []
    for i in range(1, N_TRANSACOES + 1):
        tipo = "DEPOSITO" if rng.random() < 0.70 else "SAQUE"
        metodo = "CARTAO" if tipo == "DEPOSITO" and rng.random() < 0.25 else "PIX"
        provedor = "PAGAJA" if rng.random() < 0.55 else "LIQUIDAPAY"
        r = rng.random()
        if r < 0.08:
            status = "RECUSADA"
        elif r < 0.11:
            status = "PENDENTE"
        elif r < 0.15 and tipo == "DEPOSITO":
            status = "ESTORNADA"
        else:
            status = "APROVADA"

        if status == "PENDENTE" and rng.random() < 0.7:
            criado = momento_aleatorio(rng, 30, 31)
        elif status == "ESTORNADA":
            criado = momento_aleatorio(rng, 1, 24)
        else:
            criado = momento_aleatorio(rng)

        t = {
            "id": f"TX-{i:06d}",
            "cliente": f"CL-{rng.randint(1, 1800):05d}",
            "tipo": tipo, "metodo": metodo, "provedor": provedor,
            "valor": valor_aleatorio(rng, tipo), "status": status,
            "criado": criado,
        }
        if status == "PENDENTE":
            t["atualizado"] = criado
        elif status == "ESTORNADA":
            t["atualizado"] = criado + timedelta(days=rng.randint(1, 6),
                                                 minutes=rng.randint(0, 600))
        else:
            t["atualizado"] = criado + timedelta(seconds=rng.randint(2, 180))
        t["data_local"] = criado.date()
        t["liq_esperada"] = t["data_local"] + timedelta(days=prazo(provedor, metodo, tipo))
        trans.append(t)

    # ---- 2. Sorteio dos erros (conjuntos disjuntos) ---------------------
    usados = set()
    gabarito = []

    def no_incidente(t):
        return (t["provedor"] == "LIQUIDAPAY" and t["metodo"] == "CARTAO"
                and JANELA_INCIDENTE[0] <= t["data_local"] <= JANELA_INCIDENTE[1])

    def pool(cond):
        return [t for t in trans if t["id"] not in usados and cond(t)]

    def sortear(lista, n):
        escolhidos = rng.sample(lista, n)
        usados.update(t["id"] for t in escolhidos)
        return escolhidos

    aprov_ok = lambda t: (t["status"] == "APROVADA" and t["liq_esperada"] <= FIM_MES
                          and not no_incidente(t))

    # incidente de taxa: todas as linhas de cartão da LiquidaPay na janela
    incidente = [t for t in trans if no_incidente(t)
                 and t["status"] in ("APROVADA", "ESTORNADA")
                 and t["liq_esperada"] <= FIM_MES]
    ids_incidente = {t["id"] for t in incidente}
    usados.update(ids_incidente)

    ausentes = sortear(pool(aprov_ok), N_ERROS["AUSENTE_NO_EXTRATO"])
    # duplicidade concentrada: PagaJá, liquidações de 22/10
    duplicadas = sortear(pool(lambda t: aprov_ok(t) and t["provedor"] == "PAGAJA"
                              and t["liq_esperada"] == date(2026, 10, 22)),
                         N_ERROS["DUPLICIDADE"])
    valor_div = sortear(pool(aprov_ok), N_ERROS["VALOR_DIVERGENTE"])
    atrasadas = sortear(pool(lambda t: aprov_ok(t)
                             and t["liq_esperada"] <= FIM_MES - timedelta(days=3)),
                        N_ERROS["LIQUIDACAO_ATRASADA"])
    estorno_nr = sortear(pool(lambda t: aprov_ok(t) and t["tipo"] == "DEPOSITO"
                              and t["data_local"] <= date(2026, 10, 24)),
                         N_ERROS["ESTORNO_NAO_REGISTRADO"])
    n_rec = N_ERROS["STATUS_DIVERGENTE"] * 6 // 10
    status_div = sortear(pool(lambda t: t["status"] == "RECUSADA" and not no_incidente(t)
                              and t["liq_esperada"] <= FIM_MES), n_rec)
    status_div += sortear(pool(lambda t: t["status"] == "PENDENTE" and not no_incidente(t)
                               and t["liq_esperada"] <= FIM_MES),
                          N_ERROS["STATUS_DIVERGENTE"] - n_rec)

    ids_ausentes = {t["id"] for t in ausentes}
    ids_dup = {t["id"] for t in duplicadas}
    ids_status = {t["id"] for t in status_div}
    delta_valor = {}
    for t in valor_div:
        d = Decimal(str(rng.choice([1, -1]) * rng.uniform(0.5, 60))).quantize(CENT)
        if t["valor"] + d <= 0:
            d = abs(d)
        delta_valor[t["id"]] = d
    atraso_dias = {t["id"]: rng.randint(1, 3) for t in atrasadas}
    estorno_data = {t["id"]: t["criado"] + timedelta(days=rng.randint(1, 4),
                                                     minutes=rng.randint(0, 300))
                    for t in estorno_nr}
    for t in estorno_nr:  # o estorno precisa acontecer em outubro
        if estorno_data[t["id"]].date() > FIM_MES:
            estorno_data[t["id"]] = datetime(2026, 10, 31, 12, 0, 0)

    # ---- 3. Lançamentos do provedor ------------------------------------
    lancs = []  # dicionários neutros, convertidos para cada layout depois

    def lanc(t, tipo_lanc, momento, bruto, taxa, liq_data, id_ext=None):
        lancs.append({
            "provedor": t["provedor"], "id": id_ext or t["id"], "tipo": tipo_lanc,
            "momento": momento, "bruto": bruto, "taxa": taxa,
            "liquido": liquido(tipo_lanc, bruto, taxa), "liq_data": liq_data,
        })

    for t in trans:
        movimenta = t["status"] in ("APROVADA", "ESTORNADA") or t["id"] in ids_status
        if not movimenta or t["id"] in ids_ausentes:
            continue
        liq_data = t["liq_esperada"] + timedelta(days=atraso_dias.get(t["id"], 0))
        if liq_data > FIM_MES:
            continue  # liquida em novembro: fora do extrato (armadilha)

        bruto = t["valor"] + delta_valor.get(t["id"], Decimal("0"))
        taxa = taxa_contrato(bruto, t["provedor"], t["metodo"], t["tipo"])
        if t["id"] in ids_incidente:
            taxa = (bruto * TAXA_INCIDENTE / 100).quantize(CENT, ROUND_HALF_UP)
        elif t["provedor"] == "PAGAJA" and t["metodo"] == "PIX" and t["tipo"] == "DEPOSITO":
            # armadilha: a PagaJá trunca em vez de arredondar (diferença <= 0,01)
            pct, fixa, _ = CONTRATO[("PAGAJA", "PIX", "DEPOSITO")]
            taxa = (bruto * pct / 100 + fixa).quantize(CENT, ROUND_DOWN)

        lanc(t, t["tipo"], t["criado"], bruto, taxa, liq_data)
        if t["id"] in ids_dup:
            lanc(t, t["tipo"], t["criado"], bruto, taxa, liq_data)

        # estorno legítimo (status interno ESTORNADA)
        if t["status"] == "ESTORNADA" and t["atualizado"].date() <= FIM_MES:
            lanc(t, "ESTORNO", t["atualizado"], t["valor"], Decimal("0.00"),
                 max(t["atualizado"].date(), liq_data))
        # estorno que o sistema interno não registrou
        if t["id"] in estorno_data:
            m = estorno_data[t["id"]]
            lanc(t, "ESTORNO", m, t["valor"], Decimal("0.00"), max(m.date(), liq_data))

    # transações que só existem no provedor
    orfas = []
    for k in range(N_ERROS["AUSENTE_NO_INTERNO"]):
        tipo = rng.choice(["DEPOSITO", "SAQUE"])
        prov = rng.choice(["PAGAJA", "LIQUIDAPAY"])
        momento = momento_aleatorio(rng, 1, 28)
        bruto = valor_aleatorio(rng, tipo)
        o = {"id": f"TX-{N_TRANSACOES + 900 + k * 37:06d}", "provedor": prov,
             "tipo": tipo, "metodo": "PIX"}
        taxa = taxa_contrato(bruto, prov, "PIX", tipo)
        lanc(o, tipo, momento, bruto, taxa,
             momento.date() + timedelta(days=prazo(prov, "PIX", tipo)))
        orfas.append((o, bruto))

    # ---- 4. Gabarito ---------------------------------------------------
    def add(chave, prov, cat, impacto, detalhe):
        gabarito.append({"chave": chave, "provedor": prov, "categoria": cat,
                         "impacto_rs": f"{abs(impacto):.2f}", "detalhe": detalhe})

    for t in ausentes:
        add(t["id"], t["provedor"], "AUSENTE_NO_EXTRATO", t["valor"],
            f"Aprovada no interno, liquidação esperada em {t['liq_esperada']}, sem lançamento no extrato")
    for o, bruto in orfas:
        add(o["id"], o["provedor"], "AUSENTE_NO_INTERNO", bruto,
            f"{o['tipo']} liquidado pelo provedor sem registro no sistema interno")
    for t in duplicadas:
        add(t["id"], t["provedor"], "DUPLICIDADE", t["valor"],
            "Lançamento repetido no extrato")
    for t in valor_div:
        add(t["id"], t["provedor"], "VALOR_DIVERGENTE", delta_valor[t["id"]],
            f"Bruto interno {t['valor']} x extrato {t['valor'] + delta_valor[t['id']]}")
    for t in status_div:
        add(t["id"], t["provedor"], "STATUS_DIVERGENTE", t["valor"],
            f"Interno {t['status']}, mas o provedor liquidou")
    for t in estorno_nr:
        add(t["id"], t["provedor"], "ESTORNO_NAO_REGISTRADO", t["valor"],
            "Provedor estornou; interno segue APROVADA")
    for t in atrasadas:
        add(t["id"], t["provedor"], "LIQUIDACAO_ATRASADA", t["valor"],
            f"Liquidou {atraso_dias[t['id']]} dia(s) depois do prazo ({t['liq_esperada']})")
    for t in incidente:
        cobrada = (t["valor"] * TAXA_INCIDENTE / 100).quantize(CENT, ROUND_HALF_UP)
        devida = taxa_contrato(t["valor"], t["provedor"], t["metodo"], t["tipo"])
        add(t["id"], t["provedor"], "TAXA_INCORRETA", cobrada - devida,
            f"Taxa cobrada {cobrada} x contrato {devida}")

    # ---- 5. Escrita dos arquivos ---------------------------------------
    dados = saida / "dados"
    gab_dir = saida / "gabarito"
    dados.mkdir(parents=True, exist_ok=True)
    gab_dir.mkdir(parents=True, exist_ok=True)

    with open(dados / "transacoes_internas.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["id_transacao", "id_cliente", "tipo", "metodo", "provedor",
                    "valor", "status", "criado_em", "atualizado_em"])
        for t in trans:
            w.writerow([t["id"], t["cliente"], t["tipo"], t["metodo"], t["provedor"],
                        f"{t['valor']:.2f}", t["status"],
                        t["criado"].strftime("%Y-%m-%d %H:%M:%S"),
                        t["atualizado"].strftime("%Y-%m-%d %H:%M:%S")])

    rng.shuffle(lancs)  # extrato não vem em ordem de id
    lancs_pj = sorted([l for l in lancs if l["provedor"] == "PAGAJA"],
                      key=lambda l: l["liq_data"])
    lancs_lp = sorted([l for l in lancs if l["provedor"] == "LIQUIDAPAY"],
                      key=lambda l: l["liq_data"])

    op_pj = {"DEPOSITO": "C", "SAQUE": "D", "ESTORNO": "E"}
    with open(dados / "extrato_pagaja.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, delimiter=";")
        w.writerow(["pedido", "operacao", "data_operacao", "valor_bruto", "taxa",
                    "valor_liquido", "data_liquidacao"])
        for l in lancs_pj:
            pedido = l["id"].replace("-", "").lower()
            r = rng.random()  # sujeira de digitação no id
            if r < 0.03:
                pedido = pedido.upper()
            elif r < 0.06:
                pedido = pedido + " "
            w.writerow([pedido, op_pj[l["tipo"]], l["momento"].strftime("%d/%m/%Y"),
                        br_num(l["bruto"]), br_num(l["taxa"]), br_num(l["liquido"]),
                        l["liq_data"].strftime("%d/%m/%Y")])

    et_lp = {"DEPOSITO": "SALE", "SAQUE": "PAYOUT", "ESTORNO": "REFUND"}
    with open(dados / "extrato_liquidapay.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["merchant_reference", "entry_type", "transaction_datetime_utc",
                    "gross_amount", "fee", "net_amount", "currency", "settlement_date"])
        for l in lancs_lp:
            ref = l["id"]
            r = rng.random()
            if r < 0.03:
                ref = " " + ref.lower()
            utc = l["momento"] + timedelta(hours=3)
            w.writerow([ref, et_lp[l["tipo"]], utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
                        f"{l['bruto']:.2f}", f"{l['taxa']:.2f}", f"{l['liquido']:.2f}",
                        "BRL", l["liq_data"].isoformat()])

    with open(dados / "taxas_contratadas.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["provedor", "metodo", "tipo", "taxa_pct", "taxa_fixa", "prazo_liquidacao_dias"])
        for (prov, met, tipo), (pct, fixa, pz) in CONTRATO.items():
            w.writerow([NOME_CONTRATO[prov], met, tipo, f"{pct:.2f}", f"{fixa:.2f}", pz])

    with open(gab_dir / "gabarito_divergencias.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["chave", "provedor", "categoria", "impacto_rs", "detalhe"])
        w.writeheader()
        w.writerows(sorted(gabarito, key=lambda g: (g["categoria"], g["chave"])))

    # ---- 6. Banco SQLite (tudo como texto) ------------------------------
    db = dados / "conciliacao.db"
    if db.exists():
        db.unlink()
    con = sqlite3.connect(db)
    fontes = [
        ("raw_transacoes_internas", "transacoes_internas.csv", ","),
        ("raw_extrato_pagaja", "extrato_pagaja.csv", ";"),
        ("raw_extrato_liquidapay", "extrato_liquidapay.csv", ","),
        ("raw_taxas_contratadas", "taxas_contratadas.csv", ","),
    ]
    for tabela, arquivo, sep in fontes:
        with open(dados / arquivo, encoding="utf-8") as f:
            linhas = list(csv.reader(f, delimiter=sep))
        cols = linhas[0]
        con.execute(f"CREATE TABLE {tabela} ({', '.join(c + ' TEXT' for c in cols)})")
        con.executemany(f"INSERT INTO {tabela} VALUES ({', '.join('?' * len(cols))})", linhas[1:])
    con.commit()
    con.close()

    print(f"Seed {seed}: {len(trans)} transações internas, "
          f"{len(lancs_pj)} linhas PagaJá, {len(lancs_lp)} linhas LiquidaPay, "
          f"{len(gabarito)} divergências no gabarito.")
    print(f"Arquivos em {saida.resolve()}")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description="Gera a massa sintética do Projeto 1.")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--saida", type=Path, default=Path(__file__).resolve().parent.parent,
                   help="pasta raiz do projeto (padrão: a pasta acima de src/)")
    a = p.parse_args()
    gerar(a.seed, a.saida)
