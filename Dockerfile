FROM centos:7

COPY lgtoclnt-8.2.4.7-1.x86_64.rpm lgtoserv-8.2.4.7-1.x86_64.rpm lgtonode-8.2.4.7-1.x86_64.rpm /

RUN yum install -y socat
RUN yum localinstall --nogpgcheck -y /lgtoclnt-8.2.4.7-1.x86_64.rpm \
        /lgtoserv-8.2.4.7-1.x86_64.rpm /lgtonode-8.2.4.7-1.x86_64.rpm

COPY recover.sh /
COPY bootstrap.sh /

ENV RECOVERY_AREA /recovery_area
ENV RECOVERY_SOCKET_PATH "$RECOVERY_AREA/networker.socket"
ENV RECOVERY_SOCKET "unix-listen:$RECOVERY_SOCKET_PATH,reuseaddr,fork,mode=0600,unlink-early=1"

ENTRYPOINT [ "/bootstrap.sh" ]
