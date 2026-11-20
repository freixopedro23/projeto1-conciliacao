-- =====================================================================
-- 03_casamento.sql  –  Etapa 3: casamento das bases (PostgreSQL)
-- Responde: o que está no interno e não no extrato, o contrário,
-- e o que aparece repetido no extrato.
-- Saída: views conc_duplicidades e conc_casamento (usadas nas etapas 4 e 5).
-- =====================================================================


-- ---------------------------------------------------------------------
-- 3.1 Duplicidade, forma simples: GROUP BY ... HAVING
-- O tipo de lançamento entra no agrupamento: um depósito e o estorno
-- dele têm o mesmo id, mas não são duplicidade.
-- ---------------------------------------------------------------------
SELECT
    id_provedor,
    id_transacao,
    ds_tp_lancamento,
    COUNT(*) AS qt_ocorrencias
FROM stg_extrato
WHERE ds_tp_lancamento <> 'ESTORNO'
GROUP BY id_provedor, id_transacao, ds_tp_lancamento
HAVING COUNT(*) > 1
ORDER BY id_transacao;


-- ---------------------------------------------------------------------
-- 3.2 Duplicidade com ROW_NUMBER(): a mesma resposta, agora separando
-- a primeira ocorrência (que segue para o casamento) das repetidas.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW conc_duplicidades AS
WITH extrato_mov AS (
    -- só movimentos: os estornos são tratados na etapa 4
    SELECT *
    FROM stg_extrato
    WHERE ds_tp_lancamento IN ('DEPOSITO', 'SAQUE')
),
extrato_numerado AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY id_provedor, id_transacao, ds_tp_lancamento
            ORDER BY dt_liquidacao, dt_lancamento
        ) AS nr_ocorrencia
    FROM extrato_mov
)
SELECT *
FROM extrato_numerado
WHERE nr_ocorrencia > 1;      -- só as repetidas (a nº 1 é a legítima)

-- Conferência: deve dar a mesma quantidade de transações da 3.1
SELECT COUNT(DISTINCT id_transacao) AS transacoes_duplicadas,
       COUNT(*)                     AS linhas_excedentes
FROM conc_duplicidades;


-- ---------------------------------------------------------------------
-- 3.3 Casamento: interno esperado x extrato sem duplicatas
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW conc_casamento AS
WITH extrato_mov AS (
    SELECT *
    FROM stg_extrato
    WHERE ds_tp_lancamento IN ('DEPOSITO', 'SAQUE')
),
extrato_numerado AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY id_provedor, id_transacao, ds_tp_lancamento
            ORDER BY dt_liquidacao, dt_lancamento
        ) AS nr_ocorrencia,
        COUNT(*) OVER (
            PARTITION BY id_provedor, id_transacao, ds_tp_lancamento
        ) AS qt_ocorrencias
    FROM extrato_mov
),
extrato_dedup AS (
    SELECT *
    FROM extrato_numerado
    WHERE nr_ocorrencia = 1
),
interno_esperado AS (
    -- O que DEVERIA estar no extrato: movimenta dinheiro (APROVADA ou
    -- ESTORNADA) e a liquidação prevista cai até 31/10, a data de corte
    -- dos extratos. Transações do fim do mês que liquidam em novembro
    -- ficam de fora: não é erro, é calendário.
    SELECT
        t.*,
        ta.vl_taxa_pct,
        ta.vl_taxa_fixa,
        ta.qt_prazo_liquidacao_dias,
        t.dt_transacao + ta.qt_prazo_liquidacao_dias AS dt_liquidacao_esperada
    FROM stg_transacoes t
    JOIN stg_taxas ta
      ON  ta.id_provedor     = t.id_provedor
      AND ta.ds_metodo_pagto = t.ds_metodo_pagto
      AND ta.ds_tp_transacao = t.ds_tp_transacao
    WHERE t.ds_status IN ('APROVADA', 'ESTORNADA')
      AND t.dt_transacao + ta.qt_prazo_liquidacao_dias <= DATE '2026-10-31'
),
casamento AS (
    SELECT
        COALESCE(i.id_transacao, e.id_transacao)   AS id_transacao,
        COALESCE(i.id_provedor,  e.id_provedor)    AS id_provedor,
        CASE
            WHEN i.id_transacao IS NOT NULL AND e.id_transacao IS NOT NULL THEN 'CASADA'
            WHEN e.id_transacao IS NULL                                    THEN 'SO_NO_INTERNO'
            ELSE 'SO_NO_EXTRATO'
        END                                        AS ds_situacao,
        -- lado interno
        i.ds_status,
        i.ds_tp_transacao,
        i.ds_metodo_pagto,
        i.vl_bruto                                 AS vl_bruto_interno,
        i.dt_transacao,
        i.dt_liquidacao_esperada,
        i.vl_taxa_pct,
        i.vl_taxa_fixa,
        i.qt_prazo_liquidacao_dias,
        -- lado extrato
        e.ds_tp_lancamento,
        e.vl_bruto                                 AS vl_bruto_extrato,
        e.vl_taxa                                  AS vl_taxa_extrato,
        e.vl_liquido                               AS vl_liquido_extrato,
        e.dt_lancamento                            AS dt_lancamento_extrato,
        e.dt_liquidacao                            AS dt_liquidacao_extrato,
        e.qt_ocorrencias                           AS qt_ocorrencias_extrato
    FROM interno_esperado i
    FULL OUTER JOIN extrato_dedup e
      ON  e.id_transacao = i.id_transacao
      AND e.id_provedor  = i.id_provedor
)
SELECT
    c.*,
    -- "Só no extrato" tem dois casos diferentes:
    --   o interno nem conhece o id, ou conhece mas com status que não movimenta
    CASE
        WHEN c.ds_situacao <> 'SO_NO_EXTRATO' THEN NULL
        WHEN t.id_transacao IS NULL           THEN 'ID_DESCONHECIDO_NO_INTERNO'
        ELSE 'INTERNO_COM_STATUS_' || t.ds_status
    END AS ds_motivo_so_no_extrato
FROM casamento c
LEFT JOIN stg_transacoes t
  ON  c.ds_situacao  = 'SO_NO_EXTRATO'
  AND t.id_transacao = c.id_transacao
  AND t.id_provedor  = c.id_provedor;


-- ---------------------------------------------------------------------
-- 3.4 Resumo do casamento
-- ---------------------------------------------------------------------
SELECT
    id_provedor,
    ds_situacao,
    ds_motivo_so_no_extrato,
    COUNT(*)                                          AS qt_transacoes,
    SUM(COALESCE(vl_bruto_interno, vl_bruto_extrato)) AS vl_bruto_total
FROM conc_casamento
GROUP BY id_provedor, ds_situacao, ds_motivo_so_no_extrato
ORDER BY id_provedor, ds_situacao, ds_motivo_so_no_extrato;