#!/bin/bash

INDEX=patent-documents
ES_HOST=localhost
ES_PORT=9200

function list () {
  curl -X GET 'localhost:9200/_cat/indices?v'
}

function create() {
  curl -X PUT "$ES_HOST:$ES_PORT/$INDEX" \
     -H 'Content-Type: application/json' \
     -d '
      {
        "settings": {
          "number_of_shards": 1,
          "number_of_replicas": 0
        }
      }' 

}

function delete() {
  curl -X DELETE "$ES_HOST:$ES_PORT/$INDEX?pretty" 
}

function search() {
  curl -sS -X GET "$ES_HOST:$ES_PORT/$INDEX/_search?pretty" \
       -H 'Content-Type: application/json' \
       -d '
{
  "query":{
    "match_all":{
    }
  },
  "from":0,
  "size":3
}'
}

while getopts e:p:i: OPT
do
  case $OPT in
  e) ES_HOST=$OPTARG
     ;;
  p) ES_PORT=$OPTARG
     ;;
  i) INDEX=$OPTARG
     ;;
  *) exit 1
     ;;
  esac
done

shift $((OPTIND - 1)) # オプション部分をスキップ

case $1 in
  "list")
    list
    ;;
  "delete")
    delete
    ;;
  "create")
    create
    ;;
  "search")
    search
    ;;
  *)
    list
    exit 1
  ;;
esac

