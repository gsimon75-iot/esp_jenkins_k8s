FROM jenkins/jnlp-slave
ARG TOOLCHAIN_TARBALL=xtensa-lx106-elf-linux64-1.22.0-100-ge567ec7-5.2.0.tar.gz
ARG SDK_GH_TAG=master
ARG TOOLKIT_BASE=/home/jenkins/esp
ENV PATH="$TOOLKIT_BASE/xtensa-lx106-elf/bin:$PATH"
ENV IDF_PATH="$TOOLKIT_BASE/ESP8266_RTOS_SDK"

USER root
COPY $TOOLCHAIN_TARBALL /tmp/toolchain.tar.gz
RUN apt-get update ;\
    apt-get install -y gcc git wget make ncurses-dev flex bison gperf libc-dev libffi-dev openssl \
        python python-dev python-pip python-serial python-click python-future python-pyparsing ;\
    apt-get clean

# user=jenkins, uid=1000
USER jenkins
RUN mkdir -p $TOOLKIT_BASE ;\
    cd $TOOLKIT_BASE ;\
    tar -x -z -f /tmp/toolchain.tar.gz ;\
    git clone https://github.com/espressif/ESP8266_RTOS_SDK.git ;\
    cd $IDF_PATH ;\
    git checkout $SDK_GH_TAG ;\
    git submodule update --init --recursive
COPY sdkconfig.default $TOOLKIT_BASE/

USER root
RUN rm /tmp/toolchain.tar.gz ;\
    pip install -r $IDF_PATH/requirements.txt
USER jenkins

# vim: set sw=4 ts=4 et indk= :
