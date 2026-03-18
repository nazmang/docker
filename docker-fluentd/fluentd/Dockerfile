FROM fluentd:v1.19.2-debian-1.0

USER root

RUN gem install fluent-plugin-opensearch --no-document && \
    gem sources --clear-all   

USER fluent