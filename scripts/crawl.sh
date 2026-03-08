#!/bin/bash

SCRIPT_DIR=$(dirname $0)
PROJECT_DIR="$SCRIPT_DIR/.."

# default vars.
MODE=prod
TARGET=ALL
NUM_MULTI_PROCESSORS="-m 1"
OVERWRITE=""


list_of_targets(){
    echo "-t {target}: Specify the target for crawling. Supported targets are: ALL, APP_DOC, AMND, RSPN, ETC, NOTICE"
    echo "Supported target codes are:"

    echo
    echo "NOTICE"
    echo -e "\tA101"     特許査定
    echo -e "\tA102"     拒絶査定
    echo -e "\tA1131"    拒絶理由通知書
    echo -e "\tA1191"    補正却下の決定
    #echo -e "\tA1192"    補正却下の決定
    echo -e "\tA130"     引用非特許文献
    echo -e "\tA2242623" 実用新案技術評価の通知

    echo 
    echo "APP_DOC"
    echo -e "\tA163"  特許願
    echo -e "\tA263"  実用新案登録願
    echo -e "\tA1631" 翻訳文提出書
    echo -e "\tA1632" 国内書面
    #echo -e "\tA2633", 図面の提出書（実案）は対象外(データないので確認できない)
    echo -e "\tA1634" 国際出願翻訳文提出書
    #echo -e "\tA1635", 国際出願翻訳文提出書（職権）は対象外(データないので確認できない)

    echo
    echo "AMND"
    echo -e "\tA151"   手続補正書（方式）,手続補正書
    echo -e "\tA1523"  手続補正書 特許
    echo -e "\tA2523"  手続補正書 実案
    #echo -e "\tA1524"  誤訳訂正書
    #echo -e "\tA1525"  特許協力条約第１９条補正の翻訳文提出書
    echo -e "\tA1529"  特許協力条約第３４条補正の翻訳文提出書
    #echo -e "\tA1526"  特許協力条約第１９条補正の翻訳文提出書（職権）
    #echo -e "\tA15210" 特許協力条約第３４条補正の翻訳文提出書（職権）
    echo -e "\tA1527"  特許協力条約第１９条補正の写し提出書
    echo -e "\tA15211" 特許協力条約第３４条補正の写し提出書
    #echo -e "\tA1528"  特許協力条約第１９条補正の写し提出書（職権）
    #echo -e "\tA15212" 特許協力条約第３４条補正の写し提出書（職権）

    echo
    echo "RSPN"
    echo -e "\tA153" 意見書
    #echo -e "\tA159" 弁明書

    echo
    echo "ETC"
    echo -e "\tA1781" 上申書
    echo -e "\tA1871" 早期審査に関する事情説明書
    echo -e "\tA1872" 早期審査に関する事情説明補充書

    echo
    echo "ALL 以上の全て"
}

usage(){
    echo "Usage: $0 [-m {num_multi_processors}] [-o] [-t {target}] [ -d ]"
    echo "  -m: Number of multi-processors to use for crawling. Default is 1. max is 4"
    echo "  -o: Overwrite existing data in the data_dir. WARNING: This will delete all existing data in the data_dir."
    echo "  -t: Specify the target for crawling. default is ALL"
    echo "  -d: execute this script for debug."
    echo 
    echo "for development, SRC_DIR, DATA_DIR must be defined in .env file."
    echo "for production, these variables are imported in docker-compose.yml."
}

while getopts "lom:t:d" opt; do
  case $opt in
    m)
      NUM_MULTI_PROCESSORS="-m $OPTARG"
      ;;
    o)
      OVERWRITE="-o"
      ;;
    t)
      TARGET="$OPTARG"
      ;;
    d)
      MODE=dev
      ;;
    l)
      list_of_targets
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

PAT_APP_DOC_CODES="A163 A263 A1631 A1632 A1634"
PAT_AMND="A151 A1523 A1529 A1527 A15211 A2523"
PAT_RSPN="A153"
PAT_ETC="A1781 A1871 A1872"
NOTICE="A101 A102 A1131 A1191 A130 A2242623"
ALL="$PAT_APP_DOC_CODES $PAT_AMND $PAT_RSPN $PAT_ETC $NOTICE"
case $TARGET in
  "ALL")
    TARGET_CODES="$ALL"
    ;;
  "APP_DOC")
    TARGET_CODES="$PAT_APP_DOC_CODES"
    ;;
  "AMND")
    TARGET_CODES="$PAT_AMND"
    ;;
  "RSPN")
    TARGET_CODES="$PAT_RSPN"
    ;;
  "ETC")
    TARGET_CODES="$PAT_ETC"
    ;;
  "NOTICE")
    TARGET_CODES="$NOTICE"
    ;;
  *)
    echo "Invalid target specified. Supported targets are: ALL, APP_DOC, AMND, RSPN, ETC, NOTICE"
    exit 1
    ;;
esac

if [ "$MODE" = "prod" ]; then
  docker compose -f $PROJECT_DIR/docker-compose.yml \
    run --rm -i mona \
      $OVERWRITE $NUM_MULTI_PROCESSORS \
      /src_dir /data_dir $TARGET_CODES
elif [ "$MODE" = "dev" ]; then
  source $PROJECT_DIR/.env
  export SRC_DIR DATA_DIR
  uv run $PROJECT_DIR/mona/src/mona/main.py \
      $OVERWRITE $NUM_MULTI_PROCESSORS \
      $SRC_DIR $DATA_DIR $TARGET_CODES
else
  usage
fi
