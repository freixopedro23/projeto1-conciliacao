-- =====================================================================
-- 05_relatorio.sql  –  Etapa 5: relatório de divergências (PostgreSQL)
--
-- Transforma os achados da etapa 4 (view conc_achados) no relatório
-- do fechamento de outubro/2026:
--   5.1 tabela divergencias (foto do fechamento)
--   5.2 resumo por provedor e categoria
--   5.3 quem age e qual é o risco
--   5.4 série diária com acumulado do mês (SUM() OVER)
--   5.5 incidentes: erros concentrados em um provedor ou período
--
-- Impacto: nos resumos, usa-se ABS(impacto_rs) para medir o tamanho do
-- problema. Sem o ABS, as diferenças positivas e negativas do
-- VALOR_DIVERGENTE se anulariam na soma.
-- =====================================================================


-- =====================================================================
-- 5.1 TABELA DIVERGENCIAS
-- Tabela, e não view: o relatório de um fechamento é uma foto. Se os
-- dados forem corrigidos depois, o relatório de outubro não muda sozinho.
--
-- Grão: um achado por transação e categoria. A chave é composta porque
-- uma mesma transação pode ter mais de um achado (ex.: valor divergente
-- e liquidação atrasada).
-- Coluna impacto_rs: o enunciado chama de impacto_r$; o "$" foi trocado
-- por "s" para evitar aspas e problemas em outras ferramentas.
-- data_referencia: regra definida no cabeçalho do 04_validacoes.sql.
-- =====================================================================
DROP TABLE IF EXISTS divergencias;

CREATE TABLE divergencias (
    chave            VARCHAR(9)     NOT NULL,
    provedor         VARCHAR(20)    NOT NULL,
    categoria        VARCHAR(50)    NOT NULL,
    impacto_rs       NUMERIC(10,2)  NOT NULL,
    detalhe          VARCHAR(255)   NOT NULL,
    data_referencia  DATE           NOT NULL,
    CONSTRAINT pk_divergencias PRIMARY KEY (chave, categoria)
);

INSERT INTO divergencias (
    chave,
    provedor,
    categoria,
    impacto_rs,
    detalhe,
    data_referencia
)
SELECT
    id_transacao,
    id_provedor,
    ds_categoria,
    vl_impacto,
    ds_detalhe,
    dt_referencia
FROM conc_achados;

-- Conferência: deve trazer os 125 achados da etapa 4
SELECT COUNT(*) AS qt_divergencias
FROM divergencias;


-- =====================================================================
-- 5.2 RESUMO POR PROVEDOR E CATEGORIA
-- =====================================================================
SELECT
    provedor,
    categoria,
    COUNT(*)                 AS qt_achados,
    SUM(ABS(impacto_rs))     AS vl_impacto
FROM divergencias
GROUP BY provedor, categoria
ORDER BY provedor, vl_impacto DESC;
-- Resultado:
--   LIQUIDAPAY: 82 achados, R$  4.148,64
--   PAGAJA:     43 achados, R$ 17.146,17
-- A LiquidaPay tem o dobro de achados, mas a PagaJá tem mais de 4x o
-- impacto: os 58 achados de taxa da LiquidaPay somam R$ 109, enquanto
-- as 10 duplicidades da PagaJá somam R$ 4.693.


-- =====================================================================
-- 5.3 QUEM AGE E QUAL É O RISCO
-- Tabela de referência com uma linha por categoria, montada com VALUES.
-- Vocabulário fechado:
--   responsavel: Provedor | Interno | Investigar
--   tipo_risco:  Financeiro (dinheiro perdido ou cobrado a mais)
--                Cliente    (cliente sem crédito ou sem receber)
--                Contábil   (saldo do sistema diferente da realidade)
--                Caixa      (dinheiro que chega, mas atrasado)
-- =====================================================================
WITH regras AS (
    SELECT *
    FROM (
        VALUES
            ('DUPLICIDADE',            'Provedor',   'Financeiro',
             'Cobrar a devolução do valor lançado em duplicidade'),
            ('TAXA_INCORRETA',         'Provedor',   'Financeiro',
             'Contestar e cobrar a diferença cobrada a mais'),
            ('LIQUIDACAO_ATRASADA',    'Provedor',   'Caixa',
             'Cobrar o cumprimento do prazo contratual de liquidação'),
            ('ESTORNO_NAO_REGISTRADO', 'Interno',    'Financeiro',
             'Marcar como estornada, ajustar o saldo do cliente e investigar a integração'),
            ('AUSENTE_NO_INTERNO',     'Investigar', 'Cliente',
             'Identificar a origem do lançamento e, se for depósito, creditar o cliente'),
            ('AUSENTE_NO_EXTRATO',     'Provedor',   'Financeiro',
             'Abrir chamado com o provedor com a lista de ids não liquidados'),
            ('STATUS_DIVERGENTE',      'Interno',    'Cliente',
             'Corrigir o status no interno e revisar a atualização de status vinda do provedor'),
            ('VALOR_DIVERGENTE',       'Provedor',   'Financeiro',
             'Cobrar ou devolver a diferença, conforme o sinal do impacto')
    ) AS r (categoria, responsavel, tipo_risco, acao)
)
SELECT
    d.provedor,
    d.categoria,
    COUNT(*)                 AS qt_achados,
    SUM(ABS(d.impacto_rs))   AS vl_impacto,
    r.responsavel,
    r.tipo_risco,
    r.acao
FROM divergencias AS d
JOIN regras AS r USING (categoria)
GROUP BY d.provedor, d.categoria, r.responsavel, r.tipo_risco, r.acao
ORDER BY d.provedor, vl_impacto DESC;


-- =====================================================================
-- 5.4 SÉRIE DIÁRIA COM ACUMULADO DO MÊS
-- Para cada provedor e cada dia de outubro: achados e impacto do dia,
-- e o acumulado do mês até aquele dia (SUM() OVER com ORDER BY).
-- Os dias sem achado entram com zero (generate_series + LEFT JOIN),
-- para a série não pular dias e o acumulado ficar parado neles.
-- =====================================================================
WITH dias AS (
    -- todos os dias de outubro
    SELECT dia::date AS dia
    FROM generate_series(DATE '2026-10-01', DATE '2026-10-31', INTERVAL '1 day') AS dia
),
provedores AS (
    SELECT DISTINCT provedor
    FROM divergencias
),
por_dia AS (
    -- achados e impacto de cada dia em que houve achado
    SELECT
        data_referencia          AS dia,
        provedor,
        COUNT(*)                 AS qt_achados_dia,
        SUM(ABS(impacto_rs))     AS vl_impacto_dia
    FROM divergencias
    GROUP BY data_referencia, provedor
),
calendario AS (
    -- todos os dias x todos os provedores, com zero nos dias vazios
    SELECT
        d.dia,
        p.provedor,
        COALESCE(pd.qt_achados_dia, 0)   AS qt_achados_dia,
        COALESCE(pd.vl_impacto_dia, 0)   AS vl_impacto_dia
    FROM dias AS d
    CROSS JOIN provedores AS p
    LEFT JOIN por_dia AS pd
      ON  pd.dia      = d.dia
      AND pd.provedor = p.provedor
)
SELECT
    provedor,
    dia,
    qt_achados_dia,
    SUM(qt_achados_dia) OVER w   AS qt_achados_acumulado,
    vl_impacto_dia,
    SUM(vl_impacto_dia) OVER w   AS vl_impacto_acumulado
FROM calendario
WINDOW w AS (
    PARTITION BY provedor        -- o acumulado recomeça em cada provedor
    ORDER BY dia                 -- e soma do dia 1 até o dia da linha
)
ORDER BY provedor, dia;
-- Conferência: no dia 31/10, o acumulado fecha com o resumo da 5.2.
-- Leitura: na LiquidaPay, o acumulado de QUANTIDADE salta de 19 para 77
-- entre 15 e 18/10, enquanto o de VALOR quase não se mexe
-- (R$ 3.060 -> R$ 3.169). Só a série em quantidade revela o incidente
-- de taxa.


-- =====================================================================
-- 5.5 INCIDENTES: ERROS CONCENTRADOS EM UM PROVEDOR OU PERÍODO
-- Muitos achados em poucos dias e em um só provedor = incidente
-- (algo mudou no provedor naquele período). Poucos achados espalhados
-- pelo mês e pelos dois provedores = casos isolados.
-- =====================================================================
SELECT
    provedor,
    categoria,
    COUNT(*)                          AS qt_achados,
    SUM(ABS(impacto_rs))              AS vl_impacto,
    MIN(data_referencia)              AS primeiro_dia,
    MAX(data_referencia)              AS ultimo_dia,
    COUNT(DISTINCT data_referencia)   AS qt_dias_com_achado
FROM divergencias
GROUP BY provedor, categoria
ORDER BY qt_achados DESC;

-- ---------------------------------------------------------------------
-- Conclusão
--
-- INCIDENTE 1 – Taxa incorreta na LiquidaPay (cartão)
--   58 achados entre 15 e 18/10, todos de depósito no cartão. A taxa
--   cobrada ficou acima do contrato em todas as transações do período.
--   Impacto: R$ 109,06 cobrados a mais. O valor é baixo, mas o padrão
--   indica uma configuração de taxa errada no provedor.
--   Ação: contestar com a LiquidaPay, pedir o estorno da diferença e a
--   confirmação de que a taxa foi corrigida a partir de 19/10.
--
-- INCIDENTE 2 – Duplicidade na PagaJá
--   10 lançamentos repetidos, todos com liquidação em 22/10.
--   Impacto: R$ 4.693,24, o maior entre todas as categorias. Um único
--   dia de liquidação sugere um arquivo ou lote processado duas vezes.
--   Ação: cobrar da PagaJá a devolução e pedir a apuração do lote de 22/10.
--
-- Casos isolados
--   As demais categorias têm poucos achados, espalhados pelo mês e
--   presentes nos dois provedores: são falhas pontuais, tratadas uma a
--   uma com as ações da 5.3.
-- ---------------------------------------------------------------------