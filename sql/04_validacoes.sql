-- =====================================================================
-- 04_validacoes.sql  –  Etapa 4: validações (PostgreSQL)
--
-- Confere o resultado do casamento (etapa 3) e transforma cada problema
-- encontrado em um "achado". Todas as validações devolvem o mesmo formato:
--
--   id_transacao | id_provedor | ds_categoria | vl_impacto | ds_detalhe | dt_referencia
--
-- Convenções
--   ds_categoria   código sem espaço nem acento (chave para as etapas 5 e 6)
--   vl_impacto     valor em R$ afetado pelo achado, sempre pelo bruto, exceto:
--                    VALOR_DIVERGENTE -> extrato − interno (positivo = o
--                                        provedor movimentou mais que o interno)
--                    TAXA_INCORRETA   -> cobrada − contrato (positivo = cobrou a mais)
--   dt_referencia  data usada na série diária da etapa 5: a data da transação,
--                  exceto em ESTORNO_NAO_REGISTRADO, que usa a data do estorno
--                  (o dia em que o dinheiro saiu sem o interno saber)
--
-- Fontes: conc_casamento e conc_duplicidades (etapa 3),
--         stg_extrato e stg_transacoes (etapa 2)
-- Saída:  view conc_achados (usada na etapa 5)
-- =====================================================================


-- =====================================================================
-- 4.1 a 4.8  LISTA ÚNICA DE ACHADOS
-- Cada validação é uma CTE; no fim, todas se juntam com UNION ALL.
-- =====================================================================
CREATE OR REPLACE VIEW conc_achados AS
WITH

-- ---------------------------------------------------------------------
-- 4.1 Valor bruto divergente
-- Casadas em que o bruto do interno difere do bruto do extrato.
-- ---------------------------------------------------------------------
div_valor AS (
    SELECT
        id_transacao,
        id_provedor,
        'VALOR_DIVERGENTE'                                                   AS ds_categoria,
        vl_bruto_extrato - vl_bruto_interno                                  AS vl_impacto,
        'Bruto interno ' || vl_bruto_interno || ' x extrato ' || vl_bruto_extrato AS ds_detalhe,
        dt_transacao                                                         AS dt_referencia
    FROM conc_casamento
    WHERE ds_situacao = 'CASADA'
      AND vl_bruto_interno <> vl_bruto_extrato
),

-- ---------------------------------------------------------------------
-- 4.2 Status divergente
-- O provedor liquidou, mas o interno tem a transação como RECUSADA ou
-- PENDENTE. Na etapa 3 elas não casam e ficam como SO_NO_EXTRATO, então
-- só o lado do extrato está preenchido.
-- ---------------------------------------------------------------------
div_status AS (
    SELECT
        id_transacao,
        id_provedor,
        'STATUS_DIVERGENTE'                                                  AS ds_categoria,
        vl_bruto_extrato                                                     AS vl_impacto,
        'Provedor liquidou; interno com status '
            || REPLACE(ds_motivo_so_no_extrato, 'INTERNO_COM_STATUS_', '')   AS ds_detalhe,
        dt_lancamento_extrato                                                AS dt_referencia
    FROM conc_casamento
    WHERE ds_situacao = 'SO_NO_EXTRATO'
      AND ds_motivo_so_no_extrato LIKE 'INTERNO_COM_STATUS_%'
),

-- ---------------------------------------------------------------------
-- 4.3 Ausente no interno
-- Lançamento no extrato cujo id não existe na base interna.
-- ---------------------------------------------------------------------
div_ausente_no_interno AS (
    SELECT
        id_transacao,
        id_provedor,
        'AUSENTE_NO_INTERNO'                                                 AS ds_categoria,
        vl_bruto_extrato                                                     AS vl_impacto,
        'Lançamento no extrato sem registro na base interna'                 AS ds_detalhe,
        dt_lancamento_extrato                                                AS dt_referencia
    FROM conc_casamento
    WHERE ds_situacao = 'SO_NO_EXTRATO'
      AND ds_motivo_so_no_extrato = 'ID_DESCONHECIDO_NO_INTERNO'
),

-- ---------------------------------------------------------------------
-- 4.4 Ausente no extrato
-- Aprovada no interno, com liquidação prevista até 31/10, sem lançamento
-- no extrato. As que só liquidam em novembro foram excluídas na etapa 3:
-- não são erro, são calendário.
-- ---------------------------------------------------------------------
div_ausente_no_extrato AS (
    SELECT
        id_transacao,
        id_provedor,
        'AUSENTE_NO_EXTRATO'                                                 AS ds_categoria,
        vl_bruto_interno                                                     AS vl_impacto,
        'Aprovada no interno; liquidação prevista em ' || dt_liquidacao_esperada
            || ', sem lançamento no extrato'                                 AS ds_detalhe,
        dt_transacao                                                         AS dt_referencia
    FROM conc_casamento
    WHERE ds_situacao = 'SO_NO_INTERNO'
),

-- ---------------------------------------------------------------------
-- Duplicidade (encontrada na etapa 3)
-- Lançamentos repetidos no extrato: cada linha excedente da view
-- conc_duplicidades (ROW_NUMBER > 1) é um achado.
-- Impacto = bruto do lançamento repetido.
-- ---------------------------------------------------------------------
div_duplicidade AS (
    SELECT
        id_transacao,
        id_provedor,
        'DUPLICIDADE'                                                        AS ds_categoria,
        vl_bruto                                                             AS vl_impacto,
        ds_tp_lancamento || ' lançado ' || nr_ocorrencia
            || ' vezes no extrato (liquidação em ' || dt_liquidacao || ')'   AS ds_detalhe,
        dt_lancamento                                                        AS dt_referencia
    FROM conc_duplicidades
),

-- ---------------------------------------------------------------------
-- 4.6 Estorno não registrado no interno
-- O provedor estornou, mas o interno não marcou a transação como
-- ESTORNADA. O filtro descreve a regra (<> 'ESTORNADA'), e não o caso
-- observado (= 'APROVADA'), para continuar certo com outras massas.
-- Impacto = bruto do estorno: no estorno a taxa não é devolvida.
-- ---------------------------------------------------------------------
div_estorno_nao_registrado AS (
    SELECT
        e.id_transacao,
        e.id_provedor,
        'ESTORNO_NAO_REGISTRADO'                                             AS ds_categoria,
        e.vl_bruto                                                           AS vl_impacto,
        'Provedor estornou em ' || e.dt_lancamento
            || '; interno segue ' || t.ds_status                             AS ds_detalhe,
        e.dt_lancamento                                                      AS dt_referencia
    FROM stg_extrato AS e
    JOIN stg_transacoes AS t
      ON  t.id_transacao = e.id_transacao
      AND t.id_provedor  = e.id_provedor
    WHERE e.ds_tp_lancamento = 'ESTORNO'
      AND t.ds_status <> 'ESTORNADA'
),

-- ---------------------------------------------------------------------
-- 4.7 Taxa cobrada x contrato
-- A taxa do contrato é calculada sobre o bruto do EXTRATO, para não
-- contar de novo as divergências de valor da 4.1. Tolerância de R$ 0,01
-- para arredondamento, como manda o contrato.
-- ---------------------------------------------------------------------
taxa_calculada AS (
    SELECT
        *,
        ROUND(vl_bruto_extrato * vl_taxa_pct / 100 + vl_taxa_fixa, 2)        AS vl_taxa_contrato
    FROM conc_casamento
    WHERE ds_situacao = 'CASADA'
),
div_taxa AS (
    SELECT
        id_transacao,
        id_provedor,
        'TAXA_INCORRETA'                                                     AS ds_categoria,
        vl_taxa_extrato - vl_taxa_contrato                                   AS vl_impacto,
        'Taxa cobrada ' || vl_taxa_extrato || ' x contrato ' || vl_taxa_contrato AS ds_detalhe,
        dt_transacao                                                         AS dt_referencia
    FROM taxa_calculada
    WHERE ABS(vl_taxa_extrato - vl_taxa_contrato) > 0.01
),

-- ---------------------------------------------------------------------
-- 4.8 Liquidação atrasada
-- Liquidou depois da data prevista (data da transação + prazo do contrato).
-- DATE − DATE devolve a diferença em dias corridos, inclusive na virada
-- do mês. Impacto = bruto, o valor que ficou retido.
-- ---------------------------------------------------------------------
div_prazo AS (
    SELECT
        id_transacao,
        id_provedor,
        'LIQUIDACAO_ATRASADA'                                                AS ds_categoria,
        vl_bruto_extrato                                                     AS vl_impacto,
        'Liquidou ' || (dt_liquidacao_extrato - dt_liquidacao_esperada)
            || ' dia(s) após o prazo (' || dt_liquidacao_esperada || ')'     AS ds_detalhe,
        dt_transacao                                                         AS dt_referencia
    FROM conc_casamento
    WHERE ds_situacao = 'CASADA'
      AND dt_liquidacao_extrato > dt_liquidacao_esperada
)

SELECT * FROM div_valor
UNION ALL
SELECT * FROM div_status
UNION ALL
SELECT * FROM div_ausente_no_interno
UNION ALL
SELECT * FROM div_ausente_no_extrato
UNION ALL
SELECT * FROM div_duplicidade
UNION ALL
SELECT * FROM div_estorno_nao_registrado
UNION ALL
SELECT * FROM div_taxa
UNION ALL
SELECT * FROM div_prazo;


-- =====================================================================
-- 4.5 SEQUÊNCIA DOS ESTORNOS (LAG)
-- Checagem de integridade: não gera achado, confirma que os estornos do
-- extrato são consistentes. Para cada transação, ordena os lançamentos
-- no tempo e traz, em cada linha, o lançamento anterior. O desempate no
-- ORDER BY garante que, no mesmo dia, o original venha antes do estorno.
--
-- Perguntas:
--   1. Há estorno sem lançamento original antes dele?
--   2. Há estorno logo depois de outro estorno (estorno em dobro)?
--   3. O estorno tem o mesmo valor bruto do original?
-- Como a ordem é cronológica, "anterior = movimento" já garante que o
-- estorno veio depois do original.
-- =====================================================================
WITH sequencia_lancamentos AS (
    SELECT
        *,
        LAG(ds_tp_lancamento) OVER w  AS tp_lancamento_anterior,
        LAG(vl_bruto)         OVER w  AS vl_bruto_anterior,
        LAG(dt_lancamento)    OVER w  AS dt_lancamento_anterior
    FROM stg_extrato
    WINDOW w AS (
        PARTITION BY id_provedor, id_transacao
        ORDER BY dt_lancamento,
                 CASE WHEN ds_tp_lancamento = 'ESTORNO' THEN 1 ELSE 0 END
    )
)
SELECT
    COUNT(*)                                                    AS qt_estornos,
    COUNT(*) FILTER (WHERE tp_lancamento_anterior IS NULL)      AS qt_sem_original,
    COUNT(*) FILTER (WHERE tp_lancamento_anterior = 'ESTORNO')  AS qt_estorno_em_dobro,
    COUNT(*) FILTER (WHERE vl_bruto <> vl_bruto_anterior)       AS qt_valor_diferente
FROM sequencia_lancamentos
WHERE ds_tp_lancamento = 'ESTORNO';
-- Resultado: 175 estornos. Todos têm o lançamento original antes deles,
-- nenhum é estorno em dobro e todos têm o mesmo valor bruto do original.


-- =====================================================================
-- 4.9 CONFERÊNCIA DOS ACHADOS
-- =====================================================================

-- Quantidade e impacto por categoria
SELECT
    ds_categoria,
    COUNT(*)          AS qt_achados,
    SUM(vl_impacto)   AS vl_impacto_total
FROM conc_achados
GROUP BY ds_categoria
ORDER BY qt_achados DESC;
-- Resultado: 125 achados em 8 categorias.

-- Achados de uma categoria (troque o filtro para ver as outras)
SELECT *
FROM conc_achados
WHERE ds_categoria = 'TAXA_INCORRETA'
ORDER BY dt_referencia, id_transacao;