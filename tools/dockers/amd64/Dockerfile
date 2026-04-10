# Copyright (c) 2021 Beijing Xiaomi Mobile Software Co., Ltd.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

ARG FROM_IMAGE=amd64/ubuntu:jammy
ARG gfw=0
FROM $FROM_IMAGE AS base-image
ENV CMAKE_VER="3.27.7"

FROM base-image AS build-in-gfw-1
ENV GITHUB_URL="hub.fastgit.org"
ENV GITHUB_RAW="raw.fastgit.org"

FROM base-image AS build-in-gfw-0
ENV GITHUB_URL="github.com"
ENV GITHUB_RAW="raw.githubusercontent.com"

FROM build-in-gfw-${gfw} AS final
# replace mirror (replace one near you)
RUN apt-get update && \
  apt-get install -q -y --no-install-recommends ca-certificates && \
  mv /etc/apt/sources.list /etc/apt/sources.list.bak && \
  echo "deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ jammy main restricted universe multiverse\n" > /etc/apt/sources.list && \
  echo "deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ jammy-updates main restricted universe multiverse\n" >> /etc/apt/sources.list && \
  echo "deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ jammy-backports main restricted universe multiverse\n" >> /etc/apt/sources.list && \
  echo "deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ jammy-security main restricted universe multiverse" >> /etc/apt/sources.list

# setup timezone
RUN echo 'Etc/UTC' > /etc/timezone && \
  ln -s /usr/share/zoneinfo/Etc/UTC /etc/localtime && \
  apt-get update && \
  apt-get install -q -y --no-install-recommends tzdata

# install packages
RUN apt-get update && apt-get install -q -y --no-install-recommends \
  bash-completion \
  dirmngr \
  gnupg2 \
  lsb-release \
  python3-pip \
  software-properties-common \
  curl

# setup ros2 sources.list (replace one near you)
RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg && \
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] https://mirrors.tuna.tsinghua.edu.cn/ros2/ubuntu/ jammy main" > /etc/apt/sources.list.d/ros2-latest.list

# setup environment
ENV LANG C.UTF-8
ENV LC_ALL C.UTF-8

# install bootstrap tools
RUN apt-get update && apt-get install --no-install-recommends -y \
  build-essential \
  git \
  wget \
  python3-colcon-common-extensions \
  python3-colcon-mixin \
  python3-rosdep \
  python3-vcstool

# install python packages
RUN pip3 install -U \
  argcomplete \
  flake8 \
  flake8-blind-except \
  flake8-builtins \
  flake8-class-newline \
  flake8-comprehensions \
  flake8-deprecated \
  flake8-docstrings \
  flake8-import-order \
  flake8-quotes \
  pytest \
  pytest-repeat \
  pytest-rerunfailures \
  lark && \
  python3 -m pip install -U numpy

# upgrade CMake
RUN mkdir -p /root/cmake_tmp && \
  wget -q https://${GITHUB_URL}/Kitware/CMake/releases/download/v${CMAKE_VER}/cmake-${CMAKE_VER}-linux-x86_64.sh -O /root/cmake_tmp/cmake.sh && \
  chmod +x /root/cmake_tmp/cmake.sh && \
  /root/cmake_tmp/cmake.sh --skip-license --prefix=/usr && \
  rm -rf /root/cmake_tmp

# install cross compiler
RUN apt-get update && apt-get install --no-install-recommends -y \
  gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
  gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf

# remove apt cache
RUN rm -rf /var/lib/apt/lists/*

CMD ["bash"]
ENV HOME /root
WORKDIR $HOME
