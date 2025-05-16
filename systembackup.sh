#!/bin/bash

#変数定義
#ホスト名
HOSTNAME=$(uname -n)
#日付
DATE=$(date +%Y%m%d%H%M)
#バックアップディレクトリ検索用正規表現
SEARCH_REXP="^[0-9]{8}$"

#script格納パス
SCRIPT_PATH="/script/bin"
#scriptファイル名
SCRIPT_FILENAME="systembackup.sh"

#config格納パス
CONFIG_PATH="/script/conf"
#configファイル名
CONFIG_FILENAME="systembackup_${HOSTNAME}.conf"
#バックアップリストファイル名
BACKUPLIST_FILENAME="systembackup_${HOSTNAME}.lst"

#バックアップ世代管理数
BK_GENERATION=1

#コマンドリターンコード格納用一時変数
RC=""
#ループ処理用一時配列
TMP_ARG=()

#バックアップ対象VG
VG_SRC="rhel"

#物理ディスク構成情報バックアップファイル名
SFBKINFO="sfinfo"
#PV構成情報バックアップファイル名
PVBKINFO="pvinfo"
#VG構成情報バックアップファイル名1
VGBKINFO="vginfo"
#VG構成情報バックアップファイル名2
VGCFGBKINFO="vgcfginfo"
#LV構成情報バックアップファイル名
LVBKINFO="lvinfo"
#マウント構成情報バックアップファイル名
MOUNTBKINFO="mountinfo"
#ブロックデバイス構成情報バックアップファイル名
BLKBKINFO="blkinfo"

#コマンド関連
#NFSマウントオプション
MOUNTTYPE_NFS="nfs"
#xfsマウントオプション
MOUNTTYPE_XFS="xfs"
#スナップショットマウントオプション
MOUNTOP_SS="ro,nouuid"
#NFSマウント元
NFSMOUNT_SRC="192.168.0.81:/NFSShare"
#NFSマウント先
NFSMOUNT_DST="/mnt/nfs"
#スナップショットマウント先
SSMOUNT_DST="/mnt/ssmountpoint"
#バックアップ取得先ディレクトリ
BACKUP_DST=${NFSMOUNT_DST}/${DATE}
#xfsdumpコマンドのバックアップレベル
BACKUPLEVEL=0

#----------------------------------------------

#バックアップ管理サーバのYドライブをNFSマウント
mount -t ${MOUNTTYPE_NFS} ${NFSMOUNT_SRC} ${NFSMOUNT_DST}
RC=$?

if [ ${RC} -ne 0 ]; then
    exit 255
fi

#取得日付のディレクトリをバックアップ取得領域に作成
mkdir ${BACKUP_DST}

#バックアップ処理開始
#物理ディスク構成情報をバックアップ
TMP_ARG=($(cat ${CONFIG_PATH}/${BACKUPLIST_FILENAME} | grep -v "^#" | awk -F, '!a[$1]++ {print $1}'))

for TARGET in ${TMP_ARG[@]}
do
    if [ ${TARGET} != "" ]; then
        SUFFIX=$(basename ${TARGET})
        sfdisk -d ${TARGET} > ${BACKUP_DST}/${SFBKINFO}_${SUFFIX}
    fi
done

#PV構成情報をバックアップ
pvdisplay -v > ${BACKUP_DST}/${PVBKINFO}

#VG構成情報をバックアップ1
vgdisplay -v > ${BACKUP_DST}/${VGBKINFO}

#VG構成情報をバックアップ2
TMP_ARG=($(cat ${CONFIG_PATH}/${BACKUPLIST_FILENAME} | grep -v "^#" | awk -F, '!a[$3]++ {print $3}'))

for TARGET in ${TMP_ARG[@]}
do
    if [ ${TARGET} != "" ]; then
        SUFFIX=${TARGET}
        vgcfgbackup ${TARGET} -f ${BACKUP_DST}/${VGCFGBKINFO}_${SUFFIX}
    fi
done

#LV構成情報をバックアップ
lvdisplay -v > ${BACKUP_DST}/${LVBKINFO}

#マウント構成情報をバックアップ
mount > ${BACKUP_DST}/${MOUNTBKINFO}

#ブロックデバイス構成情報をバックアップ
blkid > ${BACKUP_DST}/${BLKBKINFO}


while read line; do
    #コンフィグを各変数に取得
    COL3_VGNAME=$(echo ${line} | awk -F, '{print $3}')
    COL4_LVNAME=$(echo ${line} | awk -F, '{print $4}')
    COL5_BKDEVICENAME=$(echo ${line} | awk -F, '{print $5}')
    COL6_SNAPSHOTFLG=$(echo ${line} | awk -F, '{print $6}')
    COL7_BKCMD=$(echo ${line} | awk -F, '{print $7}')
    COl8_BKFILENAME=$(echo ${line} | awk -F, '{print $8}')

    #バックアップコマンドを実行
    case ${COL7_BKCMD} in
        #xfsdumpによるバックアップ
        xfsdump)
            #LVMスナップショットを作成
            if [ ${COL6_SNAPSHOTFLG} -eq 1 ]; then
                lvcreate -s -l 100%FREE -n ${COL4_LVNAME}_snap ${COL5_BKDEVICENAME}

                RC=$?

                if [ ${RC} -ne 0 ]; then
                    exit 255
                fi

                #スナップショット領域をマウント
                SNAPSHOTNAME=${COL3_VGNAME}"-"${COL4_LVNAME}_snap
                mount -t ${MOUNTTYPE_XFS} -o ${MOUNTOP_SS} "/dev/mapper/"${SNAPSHOTNAME} ${SSMOUNT_DST}

                RC=$?

                if [ ${RC} -ne 0 ]; then
                    exit 255
                fi

            fi

            #バックアップ取得
            xfsdump -M ${COL4_LVNAME} -L ${DATE} -l ${BACKUPLEVEL} -f ${BACKUP_DST}/${COl8_BKFILENAME}".dump" "/dev/mapper/"${SNAPSHOTNAME}

            RC=$?   

            if [ ${RC} -ne 0 ]; then
                exit 255
            fi

            #スナップショット領域をアンマウント
            umount -f ${SSMOUNT_DST}

            RC=$?

            if [ ${RC} -ne 0 ]; then
                exit 255
            fi

            #LVMスナップショットを削除
            lvremove -fy "/dev/mapper/"${SNAPSHOTNAME}

            RC=$?

            if [ ${RC} -ne 0 ]; then
                exit 255
            fi
            ;;

        #tarによるバックアップ
        tar)
            tar cfz ${BACKUP_DST}/${COl8_BKFILENAME}".tar.gz" ${COL5_BKDEVICENAME}

            RC=$?

            if [ ${RC} -ne 0 ]; then
                exit 255
            fi
            ;;
    esac

done < <(cat ${CONFIG_PATH}/${BACKUPLIST_FILENAME} | grep -v "^#")

#取得したバックアップを圧縮
#ファイル圧縮
tar cfz ${NFSMOUNT_DST}/${DATE}_${HOSTNAME}_systembakcup.tar.gz -C ${BACKUP_DST} .

RC=$?

if [ ${RC} -ne 0 ]; then
    exit 255
fi

#圧縮前のバックアップディレクトリを削除
rm -rf ${BACKUP_DST}

#バックアップ処理終了

#世代管理
#バックアップディレクトリ数をカウント
BACKUP_FILECNT=$(ls -1 ${NFSMOUNT_DST} | wc -l)
#削除するディレクトリ数をカウント
REMOVE_FILECNT=$((BACKUP_FILECNT - BK_GENERATION))
#削除するディレクトリを配列に格納
REMOVETARGERT=($(ls -1tr ${NFSMOUNT_DST} | head -${REMOVE_FILECNT}))

#バックアップディレクトリを削除
for TARGET in ${REMOVETARGERT[@]}
do
    if [ ${TARGET} != "" ]; then
        rm -rf ${NFSMOUNT_DST}/${TARGET}
    fi
done

#バックアップ管理サーバのYドライブをNFSアンマウント
umount ${NFSMOUNT_DST}
