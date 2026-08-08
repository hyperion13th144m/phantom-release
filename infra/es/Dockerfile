FROM docker.elastic.co/elasticsearch/elasticsearch:9.3.1

# doc-mapping.json / img-mapping.json が使うアナライザ
RUN bin/elasticsearch-plugin install --batch analysis-icu \
    && bin/elasticsearch-plugin install --batch analysis-kuromoji
