{% macro log_incremental_run(model_name, phase) %}
    {#-
        Journalise les runs incrémentaux dans FINTRACK_PROD.AUDIT.dbt_run_log.

        Usage dans un modèle :
            pre_hook = "{{ log_incremental_run('fct_transactions', 'pre') }}"
            post_hook = "{{ log_incremental_run('fct_transactions', 'post') }}"

        La table doit être créée au préalable — voir scripts/snowflake/05_audit_tables.sql
    -#}

    {% if execute %}
        {% set query %}
            insert into {{ target.database }}.audit.dbt_run_log (
                run_id, model_name, phase, invocation_id,
                target_name, run_started_at, logged_at
            )
            values (
                '{{ invocation_id }}',
                '{{ model_name }}',
                '{{ phase }}',
                '{{ invocation_id }}',
                '{{ target.name }}',
                '{{ run_started_at }}',
                current_timestamp()
            )
        {% endset %}
        {{ log("Logging " ~ phase ~ " hook for " ~ model_name, info=True) }}

        {#-
            ATTENTION : ne jamais "désactiver" du Jinja avec `--`.
            Le `--` est un commentaire SQL, pas Jinja : l'expression est tout de
            même évaluée. C'est ce qui faisait exécuter l'INSERT ci-dessus et
            échouer fct_transactions sur `Schema 'FINTRACK_DEV.AUDIT' does not
            exist`. Pour neutraliser du Jinja, il faut un bloc de commentaire
            Jinja — et ces blocs ne s'imbriquent pas, donc on évite d'en citer
            un ici sous peine de refermer celui-ci par anticipation.

            Pour activer la journalisation réelle :
              1. créer le schéma AUDIT et la table dbt_run_log dans la base
                 cible de CHAQUE environnement (voir 05_audit_tables.sql —
                 actuellement seul FINTRACK_PROD.AUDIT existe) ;
              2. renvoyer la variable `query` au lieu du noop ci-dessous.
        -#}
        {{ return("select 1 as noop") }}
    {% endif %}
{% endmacro %}
