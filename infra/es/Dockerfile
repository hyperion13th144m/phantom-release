FROM docker.elastic.co/elasticsearch/elasticsearch:9.3.1

RUN bin/elasticsearch-plugin install analysis-icu
RUN bin/elasticsearch-plugin install analysis-kuromoji

COPY generated/*.json /mapping/
COPY init.sh /init.sh
RUN chmod +x /init.sh
