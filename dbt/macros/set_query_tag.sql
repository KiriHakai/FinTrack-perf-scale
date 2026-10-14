{#-
    ATTENTION — ne pas nommer ces macros `set_query_tag` / `unset_query_tag` :
    ces deux noms sont réservés par l'adaptateur dbt-snowflake, qui les appelle
    dans CHAQUE matérialisation pour poser puis restaurer le query tag autour du
    modèle en cours. Les macros d'un projet étant prioritaires sur celles d'un
    adaptateur, les redéfinir casse toutes les matérialisations :

        macro 'dbt_macro__unset_query_tag' takes not more than 0 argument(s)

    On préfixe donc nos macros avec `fintrack_`.
-#}

{% macro fintrack_set_query_tag() -%}
    {#-
        Positionne un query_tag Snowflake structuré pour tracer les coûts
        par équipe, projet et environnement.

        Appelé automatiquement via on-run-start dans dbt_project.yml.
        Le tag posé ici vaut pour la session ; l'adaptateur peut le surcharger
        au niveau de chaque modèle via la config `query_tag`.
    -#}
    {% if target.type == 'snowflake' %}
        {% set tag = 'team=data-eng|project=fintrack-perf-scale|target=' ~ target.name %}
        {% set sql %}
            alter session set query_tag = '{{ tag }}'
        {% endset %}
        {% do run_query(sql) %}
        {% do log("Query tag set: " ~ tag, info=True) %}
    {% endif %}
{%- endmacro %}


{% macro fintrack_unset_query_tag() -%}
    {% if target.type == 'snowflake' %}
        {% do run_query("alter session unset query_tag") %}
    {% endif %}
{%- endmacro %}
