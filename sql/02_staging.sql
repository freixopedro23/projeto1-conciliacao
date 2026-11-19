CREATE OR REPLACE VIEW stg_extrato AS
    SELECT
        'LIQUIDAPAY'                                                                AS id_provedor,
        UPPER(TRIM(merchant_reference))                                             AS id_transacao,
        CASE UPPER(TRIM(entry_type))
            WHEN 'SALE'   THEN 'DEPOSITO'
            WHEN 'PAYOUT' THEN 'SAQUE'
            WHEN 'REFUND' THEN 'ESTORNO'
            ELSE UPPER(TRIM(entry_type))
        END                                                                         AS ds_tp_lancamento,
        gross_amount::numeric(12,2)                                                 AS vl_bruto,
        fee::numeric(12,2)                                                          AS vl_taxa,
        net_amount::numeric(12,2)                                                   AS vl_liquido,
        (transaction_datetime_utc::timestamptz AT TIME ZONE 'America/Sao_Paulo')::date AS dt_lancamento,
        settlement_date::date                                                       AS dt_liquidacao
    FROM raw_extrato_liquidapay

    UNION ALL

    SELECT
        'PAGAJA'                                                                    AS id_provedor,
        OVERLAY(UPPER(TRIM(pedido)) PLACING '-' FROM 3 FOR 0)                       AS id_transacao,
        CASE UPPER(TRIM(operacao))
            WHEN 'C' THEN 'DEPOSITO'
            WHEN 'D' THEN 'SAQUE'
            WHEN 'E' THEN 'ESTORNO'
            ELSE UPPER(TRIM(operacao))
        END                                                                         AS ds_tp_lancamento,
        REPLACE(REPLACE(valor_bruto,   '.', ''), ',', '.')::numeric(12,2)           AS vl_bruto,
        REPLACE(REPLACE(taxa,          '.', ''), ',', '.')::numeric(12,2)           AS vl_taxa,
        REPLACE(REPLACE(valor_liquido, '.', ''), ',', '.')::numeric(12,2)           AS vl_liquido,
        TO_DATE(data_operacao, 'DD/MM/YYYY')                                        AS dt_lancamento,
        TO_DATE(data_liquidacao, 'DD/MM/YYYY')                                      AS dt_liquidacao
    FROM raw_extrato_pagaja
;

CREATE OR REPLACE VIEW stg_transacoes AS
    SELECT
        UPPER(TRIM(provedor))        AS id_provedor,
        UPPER(TRIM(id_transacao))    AS id_transacao,
        UPPER(TRIM(id_cliente))      AS id_cliente,
        UPPER(TRIM(tipo))            AS ds_tp_transacao,
        UPPER(TRIM(metodo))          AS ds_metodo_pagto,
        UPPER(TRIM(status))          AS ds_status,
        valor::numeric(12,2)         AS vl_bruto,
        criado_em::timestamp         AS ts_criado_em,
        criado_em::timestamp::date   AS dt_transacao,
        atualizado_em::timestamp     AS ts_atualizado_em
    FROM raw_transacoes_internas
;

CREATE OR REPLACE VIEW stg_taxas AS
    SELECT
        CASE UPPER(TRIM(provedor))
            WHEN 'LIQUIDAPAY' THEN 'LIQUIDAPAY'
            WHEN 'PAGAJÁ'     THEN 'PAGAJA'
            ELSE UPPER(TRIM(provedor))
        END                                   AS id_provedor,
        UPPER(TRIM(metodo))                   AS ds_metodo_pagto,
        UPPER(TRIM(tipo))                     AS ds_tp_transacao,
        taxa_pct::numeric(6,2)                AS vl_taxa_pct,
        taxa_fixa::numeric(12,2)              AS vl_taxa_fixa,
        prazo_liquidacao_dias::int            AS qt_prazo_liquidacao_dias
    FROM raw_taxas_contratadas
;