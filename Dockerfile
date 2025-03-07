######################
# aws output handler #
######################

# includes:
#   - the cmg modules
#   - dependencies

FROM ubuntu:24.04 

## needed apt packages
ARG BUILD_PACKAGES="wget git ssh bzip2 curl axel"
# needed conda packages (only packages not in the requirements of cmg-package)
ARG CONDA_PACKAGES="python==3.12.3 snakemake==8.16.0"
ENV MAMBA_ROOT_PREFIX=/opt/conda/
ENV PATH /opt/micromamba/bin:/opt/conda/bin:$PATH
# ADD credentials on build
ARG SSH_PRIVATE_KEY
##  ENV SETTINGS during runtime
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
ENV PATH=/opt/conda/bin:/opt/CADD-scripts/:$PATH
ENV DEBIAN_FRONTEND noninteractive
ENV CADD=/opt/CADD-scripts
SHELL ["/bin/bash", "-l", "-c"]

# install base packages
RUN echo "Acquire::http::Pipeline-Depth 0;" > /etc/apt/apt.conf.d/99fixbadproxy && \
    echo "Acquire::http::No-Cache true;" >> /etc/apt/apt.conf.d/99fixbadproxy && \
    echo "Acquire::BrokenProxy    true;" >> /etc/apt/apt.conf.d/99fixbadproxy && \
    apt-get -y update && \
    apt-get -y upgrade && \
    apt-get install -y $BUILD_PACKAGES && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install conda/miniforge3
RUN curl -L -O "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-$(uname)-$(uname -m).sh" && \
    /bin/bash Miniforge3-$(uname)-$(uname -m).sh -b -p /opt/conda  && \
    rm Miniforge3-$(uname)-$(uname -m).sh && \
    mamba install -y -c conda-forge -c bioconda $CONDA_PACKAGES && \
    conda clean --tarballs --index-cache --packages --yes  && \
    conda config --set channel_priority strict && \
    echo ". /opt/conda/etc/profile.d/conda.sh && conda activate base" >> /etc/skel/.bashrc && \
    echo ". /opt/conda/etc/profile.d/conda.sh && conda activate base" >> ~/.bashrc

# install cadd
RUN cd /opt && \
    git clone https://github.com/geertvandeweyer/CADD-scripts.git && \
    cd CADD-scripts && \
    snakemake test/input.tsv.gz \
        --software-deployment-method conda \
        --conda-create-envs-only \
        --conda-prefix envs/conda \
        --configfile config/config_GRCh38_v1.7.yml \
        --snakefile Snakefile -c 1

COPY Install_Annotations.sh /opt/CADD-scripts/Install_Annotations.sh 
RUN chmod a+x /opt/CADD-scripts/Install_Annotations.sh