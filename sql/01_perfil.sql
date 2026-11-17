-- =====================================================================
-- 01_perfil.sql  –  Etapa 1: perfil dos dados (PostgreSQL)
-- Objetivo: conhecer as bases ANTES de conciliar. Nada aqui altera dados.
-- Cada bloco traz a pergunta, a query e o achado (comentário "Achado:").
-- =====================================================================


-- =====================================================================
-- 1. VOLUME E PERÍODO
-- =====================================================================

-- 1.1 Quantas linhas há em cada tabela?
SELECT 'raw_transacoes_internas' AS tabela, COUNT(*) AS linhas FROM raw_transacoes_internas
UNION ALL
SELECT 'raw_extrato_pagaja',     COUNT(*) FROM raw_extrato_pagaja
UNION ALL
SELECT 'raw_extrato_liquidapay', COUNT(*) FROM raw_extrato_liquidapay
UNION ALL
SELECT 'raw_taxas_contratadas',  COUNT(*) FROM raw_taxas_contratadas;
-- Achado: 6.000 internas | 3.021 PagaJá | 2.407 LiquidaPay | 6 taxas. Bate com as linhas dos CSVs.

-- 1.2 Qual é o período coberto?
-- As conversões são explícitas (TO_DATE com máscara, fuso declarado) para não
-- depender do DateStyle do servidor.
SELECT 'interno: criado_em (Brasília)' AS campo,
       MIN(criado_em::timestamp)::text AS minimo, MAX(criado_em::timestamp)::text AS maximo
FROM raw_transacoes_internas
UNION ALL
SELECT 'interno: atualizado_em (Brasília)',
       MIN(atualizado_em::timestamp)::text, MAX(atualizado_em::timestamp)::text
FROM raw_transacoes_internas
UNION ALL
SELECT 'pagaja: data_operacao',
       MIN(TO_DATE(data_operacao, 'DD/MM/YYYY'))::text, MAX(TO_DATE(data_operacao, 'DD/MM/YYYY'))::text
FROM raw_extrato_pagaja
UNION ALL
SELECT 'pagaja: data_liquidacao',
       MIN(TO_DATE(data_liquidacao, 'DD/MM/YYYY'))::text, MAX(TO_DATE(data_liquidacao, 'DD/MM/YYYY'))::text
FROM raw_extrato_pagaja
UNION ALL
SELECT 'liquidapay: transaction_datetime_utc (UTC)',
       MIN(transaction_datetime_utc::timestamptz AT TIME ZONE 'UTC')::text,
       MAX(transaction_datetime_utc::timestamptz AT TIME ZONE 'UTC')::text
FROM raw_extrato_liquidapay
UNION ALL
SELECT 'liquidapay: transaction_datetime -> Brasília',
       MIN(transaction_datetime_utc::timestamptz AT TIME ZONE 'America/Sao_Paulo')::text,
       MAX(transaction_datetime_utc::timestamptz AT TIME ZONE 'America/Sao_Paulo')::text
FROM raw_extrato_liquidapay
UNION ALL
SELECT 'liquidapay: settlement_date',
       MIN(settlement_date::date)::text, MAX(settlement_date::date)::text
FROM raw_extrato_liquidapay;
-- Achado: base interna e PagaJá cobrem 01/10 a 31/10/2026. A LiquidaPay vai de
--   2026-10-01 03:30 até 2026-11-01 02:40 em UTC: parece ter linha de NOVEMBRO, mas
--   convertida para Brasília termina em 31/10 23:40. Filtrar "outubro" pela data UTC
--   descartaria transações válidas -> converter o fuso na staging ANTES de filtrar.


-- =====================================================================
-- 2. BASE INTERNA: DISTRIBUIÇÕES
-- =====================================================================

-- 2.1 Distribuição por status: quantidade, % e valor
SELECT status,
       COUNT(*)                                              AS qtd,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)    AS pct_qtd,
       SUM(valor::numeric)                                   AS valor_total
FROM raw_transacoes_internas
GROUP BY status
ORDER BY qtd DESC;
-- Achado: 86,1% APROVADA, 8,3% RECUSADA, 2,9% PENDENTE, 2,8% ESTORNADA.
--   Só APROVADA e ESTORNADA (5.332 transações) deveriam aparecer nos extratos.

-- 2.2 Tipo, método e provedor numa só query (GROUPING SETS)
-- Cada linha traz uma dimensão preenchida e as outras nulas.
SELECT COALESCE(tipo, metodo, provedor)                      AS valor,
       CASE WHEN tipo IS NOT NULL THEN 'tipo'
            WHEN metodo IS NOT NULL THEN 'metodo'
            ELSE 'provedor' END                              AS dimensao,
       COUNT(*)                                              AS qtd,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM raw_transacoes_internas), 1) AS pct
FROM raw_transacoes_internas
GROUP BY GROUPING SETS ((tipo), (metodo), (provedor))
ORDER BY dimensao, qtd DESC;
-- Achado: PIX 82,7% x cartão 17,3% | PagaJá 54,9% x LiquidaPay 45,1% | depósito 69,5% x saque 30,5%.

-- 2.3 Cruzamento tipo x método: "saque é sempre PIX" se confirma?
SELECT tipo, metodo, COUNT(*) AS qtd
FROM raw_transacoes_internas
GROUP BY tipo, metodo
ORDER BY tipo, metodo;
-- Achado: regra confirmada: não existe SAQUE com CARTAO. Cartão só aparece em depósito.

-- 2.4 Cruzamento provedor x status (% dentro de cada provedor)
SELECT provedor, status,
       COUNT(*) AS qtd,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY provedor), 1) AS pct_no_provedor
FROM raw_transacoes_internas
GROUP BY provedor, status
ORDER BY provedor, qtd DESC;
-- Achado: perfil de status parecido nos dois provedores (aprovação de 85-87%). Nenhum provedor destoa aqui.

-- 2.5 Valores por tipo: mínimo, mediana, média, máximo
SELECT tipo,
       MIN(valor::numeric)                                                  AS minimo,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY valor::numeric)          AS mediana,
       ROUND(AVG(valor::numeric), 2)                                        AS media,
       MAX(valor::numeric)                                                  AS maximo
FROM raw_transacoes_internas
GROUP BY tipo;
-- Achado: saques têm valor típico ~3x maior (mediana R$ 370 x R$ 121). Máximos abaixo de
--   R$ 5.000; nenhum valor zerado ou negativo.

-- 2.6 Chave da base interna: o id_transacao é único?
SELECT COUNT(*) AS linhas, COUNT(DISTINCT id_transacao) AS ids_distintos
FROM raw_transacoes_internas;
-- Achado: id_transacao é único na base interna (6.000 ids distintos) -> pode ser a chave do casamento.


-- =====================================================================
-- 3. EXTRATOS: FORMATOS E QUALIDADE
-- =====================================================================

-- 3.1 Distribuição por tipo de lançamento em cada extrato
SELECT 'PAGAJA' AS provedor, operacao AS tipo_lancamento, COUNT(*) AS qtd
FROM raw_extrato_pagaja GROUP BY operacao
UNION ALL
SELECT 'LIQUIDAPAY', entry_type, COUNT(*)
FROM raw_extrato_liquidapay GROUP BY entry_type
ORDER BY provedor, qtd DESC;
-- Achado: PagaJá: 2.029 C, 896 D, 96 E | LiquidaPay: 1.591 SALE, 737 PAYOUT, 79 REFUND.
--   Os tipos mapeiam 1 para 1: C=SALE=depósito, D=PAYOUT=saque, E=REFUND=estorno.

-- 3.2 IDs: tamanho, espaços e maiúsculas/minúsculas
-- Padrão esperado: PagaJá 'tx000123' (8, minúsculas) | LiquidaPay 'TX-000123' (9, maiúsculas)
SELECT 'PAGAJA'                                                   AS provedor,
       COUNT(*)                                                   AS total,
       COUNT(*) FILTER (WHERE pedido <> TRIM(pedido))             AS com_espaco,
       COUNT(*) FILTER (WHERE pedido <> LOWER(pedido))            AS fora_do_padrao_de_caixa,
       COUNT(*) FILTER (WHERE TRIM(LOWER(pedido)) !~ '^tx[0-9]{6}$')   AS fora_do_padrao_apos_limpeza
FROM raw_extrato_pagaja
UNION ALL
SELECT 'LIQUIDAPAY',
       COUNT(*),
       COUNT(*) FILTER (WHERE merchant_reference <> TRIM(merchant_reference)),
       COUNT(*) FILTER (WHERE merchant_reference <> UPPER(merchant_reference)),
       COUNT(*) FILTER (WHERE TRIM(UPPER(merchant_reference)) !~ '^TX-[0-9]{6}$')
FROM raw_extrato_liquidapay;
-- Achado: PagaJá: 82 ids com espaço no fim e 100 em MAIÚSCULAS (182 fora do padrão).
--   LiquidaPay: 90 ids com espaço no início, todos em minúsculas.
--   Depois de TRIM + LOWER/UPPER, 100% seguem o padrão (0 fora) -> a limpeza
--   na staging resolve tudo, não há id corrompido.

-- 3.3 Tamanho dos IDs (prova, em vez de olhar uma amostra)
SELECT 'PAGAJA' AS provedor, LENGTH(pedido) AS tamanho, COUNT(*) AS qtd
FROM raw_extrato_pagaja GROUP BY LENGTH(pedido)
UNION ALL
SELECT 'LIQUIDAPAY', LENGTH(merchant_reference), COUNT(*)
FROM raw_extrato_liquidapay GROUP BY LENGTH(merchant_reference)
ORDER BY provedor, tamanho;
-- Achado: PagaJá: 2.939 com 8 caracteres e 82 com 9 (o espaço). LiquidaPay: 2.317 com 9
--   e 90 com 10. "O id tem 9 caracteres" só vale depois do TRIM.

-- 3.4 Exemplos visíveis (colchetes mostram os espaços)
SELECT '[' || pedido || ']' AS pedido_visivel FROM raw_extrato_pagaja
WHERE pedido <> TRIM(pedido) OR pedido <> LOWER(pedido) LIMIT 5;

SELECT '[' || merchant_reference || ']' AS ref_visivel FROM raw_extrato_liquidapay
WHERE merchant_reference <> TRIM(merchant_reference) OR merchant_reference <> UPPER(merchant_reference) LIMIT 5;

-- 3.5 Formato dos números
-- PagaJá: vírgula decimal; existe ponto de milhar? E valores negativos?
SELECT COUNT(*) FILTER (WHERE valor_bruto LIKE '%.%')                       AS bruto_com_ponto_milhar,
       COUNT(*) FILTER (WHERE valor_liquido LIKE '-%')                      AS liquido_negativo,
       COUNT(*) FILTER (WHERE valor_bruto !~ '^-?[0-9]{1,3}(\.[0-9]{3})*,[0-9]{2}$') AS bruto_fora_do_formato,
       MIN(valor_bruto) FILTER (WHERE valor_bruto LIKE '%.%')               AS exemplo_com_ponto
FROM raw_extrato_pagaja;
-- Achado: vírgula decimal confirmada, e 150 valores brutos têm PONTO DE MILHAR
--   (ex.: '1.003,12'). Um REPLACE(',', '.') sozinho geraria '1.003.12' e quebraria
--   o CAST -> primeiro remover o ponto, depois trocar a vírgula. 992 líquidos
--   negativos (saques e estornos). Todos os valores seguem o formato esperado.

-- LiquidaPay: ponto decimal, sem separador de milhar?
SELECT COUNT(*) FILTER (WHERE gross_amount !~ '^[0-9]+\.[0-9]{2}$')         AS gross_fora_do_formato,
       COUNT(*) FILTER (WHERE net_amount LIKE '-%')                         AS net_negativo,
       STRING_AGG(DISTINCT currency, ', ')                                  AS moedas
FROM raw_extrato_liquidapay;
-- Achado: ponto decimal, sem separador de milhar, 100% no formato. 816 líquidos
--   negativos. Moeda única: BRL.

-- 3.6 Formato das datas
SELECT 'pagaja data_operacao'   AS campo, COUNT(*) FILTER (WHERE data_operacao   !~ '^[0-9]{2}/[0-9]{2}/[0-9]{4}$') AS fora_do_formato FROM raw_extrato_pagaja
UNION ALL
SELECT 'pagaja data_liquidacao',          COUNT(*) FILTER (WHERE data_liquidacao !~ '^[0-9]{2}/[0-9]{2}/[0-9]{4}$') FROM raw_extrato_pagaja
UNION ALL
SELECT 'liquidapay datetime_utc',         COUNT(*) FILTER (WHERE transaction_datetime_utc !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$') FROM raw_extrato_liquidapay
UNION ALL
SELECT 'liquidapay settlement_date',      COUNT(*) FILTER (WHERE settlement_date !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') FROM raw_extrato_liquidapay;
-- Achado: todas as datas seguem o formato declarado no layout de cada provedor (0 fora do formato).

-- 3.7 Fuso: quantas linhas da LiquidaPay mudam de dia ao converter UTC -> Brasília?
SELECT COUNT(*) AS total,
       COUNT(*) FILTER (
           WHERE (transaction_datetime_utc::timestamptz AT TIME ZONE 'UTC')::date
              <> (transaction_datetime_utc::timestamptz AT TIME ZONE 'America/Sao_Paulo')::date
       ) AS muda_de_dia
FROM raw_extrato_liquidapay;
-- Achado: 517 linhas (21%) da LiquidaPay caem em OUTRO DIA quando convertidas de UTC para
--   Brasília (transações entre 21h e 23h59). Comparar datas sem converter o fuso
--   geraria falsas divergências de data e de prazo.

-- 3.8 Campos vazios nas colunas principais
SELECT 'interno'    AS base,
       COUNT(*) FILTER (WHERE id_transacao = '' OR valor = '' OR status = '' OR criado_em = '') AS linhas_com_vazio
FROM raw_transacoes_internas
UNION ALL
SELECT 'pagaja',     COUNT(*) FILTER (WHERE pedido = '' OR valor_bruto = '' OR data_liquidacao = '') FROM raw_extrato_pagaja
UNION ALL
SELECT 'liquidapay', COUNT(*) FILTER (WHERE merchant_reference = '' OR gross_amount = '' OR settlement_date = '') FROM raw_extrato_liquidapay;
-- Achado: nenhum campo vazio nas colunas principais.


-- =====================================================================
-- 4. CONTRATO
-- =====================================================================

-- 4.1 Tabela de taxas completa
SELECT * FROM raw_taxas_contratadas ORDER BY provedor, metodo, tipo;

-- 4.2 Os nomes de provedor batem com os da base interna?
SELECT 'taxas' AS origem, provedor FROM raw_taxas_contratadas GROUP BY provedor
UNION ALL
SELECT 'interno', provedor FROM raw_transacoes_internas GROUP BY provedor
ORDER BY origem, provedor;
-- Achado: os nomes NÃO batem: interno usa 'PAGAJA'/'LIQUIDAPAY', o contrato usa
--   'PagaJá' (com acento) e 'LiquidaPay'. Um JOIN direto não casaria nada ->
--   padronizar o provedor na staging.


-- =====================================================================
-- 5. PRIMEIRA COMPARAÇÃO ENTRE AS BASES (ainda sem conciliar)
-- =====================================================================

-- 5.1 Por provedor: transações internas que movimentam dinheiro x linhas no extrato
WITH interno AS (
    SELECT provedor,
           COUNT(*) FILTER (WHERE status IN ('APROVADA', 'ESTORNADA')) AS movimentam,
           COUNT(*) FILTER (WHERE status = 'ESTORNADA')                AS estornadas
    FROM raw_transacoes_internas
    GROUP BY provedor
),
extrato AS (
    SELECT 'PAGAJA' AS provedor,
           COUNT(*) FILTER (WHERE operacao IN ('C', 'D')) AS movimentos,
           COUNT(*) FILTER (WHERE operacao = 'E')         AS estornos
    FROM raw_extrato_pagaja
    UNION ALL
    SELECT 'LIQUIDAPAY',
           COUNT(*) FILTER (WHERE entry_type IN ('SALE', 'PAYOUT')),
           COUNT(*) FILTER (WHERE entry_type = 'REFUND')
    FROM raw_extrato_liquidapay
)
SELECT i.provedor,
       i.movimentam, e.movimentos, e.movimentos - i.movimentam AS dif_movimentos,
       i.estornadas, e.estornos,   e.estornos - i.estornadas   AS dif_estornos
FROM interno i
JOIN extrato e USING (provedor);
-- Achado: o extrato tem MENOS movimentos que o interno (PagaJá -20, LiquidaPay -59) e
--   MAIS estornos (PagaJá +5, LiquidaPay +2). A conta não fecha nem para cima nem
--   para baixo, então há mais de um efeito somado. Hipóteses para testar na etapa 3:
--   - transações do fim do mês que só liquidam em novembro (o extrato vai até 31/10)
--   - transações que de fato não chegaram ao extrato
--   - linhas no extrato que o interno não conhece ou trata com outro status
--   - estornos feitos pelo provedor e não registrados no interno
--   - lançamentos repetidos no extrato (que inflariam a contagem e mascarariam faltas)