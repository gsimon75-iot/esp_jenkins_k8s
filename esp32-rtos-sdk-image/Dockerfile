FROM jenkins/jnlp-slave
ARG TOOLKIT_BASE=/home/jenkins/esp
ENV IDF_PATH="$TOOLKIT_BASE/esp-idf"
ENV ESPTOOL_PORT=/hostdev/ttyUSB0
ENV ESPTOOL_BAUD=460800 

USER root
RUN apt-get update ;\
    apt-get remove --purge -y python2.7 python-minimal python2.7-minimal ;\
    apt-get autoremove --purge -y ;\
    apt-get install -y vim minicom git wget libncurses-dev flex bison gperf cmake ninja-build ccache libffi-dev libssl-dev libusb-1.0-0 python3 ;\
    ln -sf /usr/bin/python3 /usr/bin/python ;\
    apt-get install -y python3-pip python3-setuptools python3-serial python3-click python3-cryptography python3-future python3-pyparsing python3-pyelftools ;\
    apt-get clean ;\
    mkdir /etc/minicom
COPY minirc /etc/minicom/minirc.dfl

# user=jenkins, uid=1000
USER jenkins
RUN echo "set bell-style none" >/home/jenkins/.inputrc ;\
    mkdir -p $TOOLKIT_BASE ;\
    cd $TOOLKIT_BASE ;\
    git clone -b v4.0 --recursive https://github.com/espressif/esp-idf.git ;\
    cd $TOOLKIT_BASE/esp-idf ;\
    tools/idf_tools.py --non-interactive install

COPY bashrc /home/jenkins/.bashrc
COPY sdkconfig.default $TOOLKIT_BASE/
COPY gcc-without-didyoumean /tmp/

USER root
# https://stackoverflow.com/questions/58735374/disabling-the-did-you-mean-suggestions-in-gcc
RUN chown jenkins:jenkins /home/jenkins/.bashrc ;\
    pip3 install -r $IDF_PATH/requirements.txt ;\
    cd /home/jenkins/.espressif/tools/xtensa-esp32-elf/*/xtensa-esp32-elf/bin/ ;\
    mv xtensa-esp32-elf-gcc xtensa-esp32-elf-gcc.didyoumean ;\
    mv /tmp/gcc-without-didyoumean xtensa-esp32-elf-gcc ;\
    chmod 755 xtensa-esp32-elf-gcc

USER jenkins

# vim: set sw=4 ts=4 et indk= :
