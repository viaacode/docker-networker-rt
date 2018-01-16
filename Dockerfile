FROM centos:7

COPY lgtoclnt-8.2.4.7-1.x86_64.rpm lgtoserv-8.2.4.7-1.x86_64.rpm lgtonode-8.2.4.7-1.x86_64.rpm /

RUN yum install -y epel-release # needed for the 'jq' package

RUN yum install -y socat jq file # 'file' required by lgto but not listed as dep

RUN yum localinstall --nogpgcheck -y /lgtoclnt-8.2.4.7-1.x86_64.rpm \
        /lgtoserv-8.2.4.7-1.x86_64.rpm /lgtonode-8.2.4.7-1.x86_64.rpm

RUN yum clean all && rm -f /lgto*.rpm

COPY recover.sh /
COPY bootstrap.sh /

ENV RecoveryAreaGid 4
ENV RecoveryArea /recovery_area
ENV RecoverySocket "unix-listen:$RecoveryArea/networker.socket,reuseaddr,fork,mode=0600,unlink-early=1"

ENTRYPOINT [ "/bootstrap.sh" ]
