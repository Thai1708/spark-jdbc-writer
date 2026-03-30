FROM eclipse-temurin:11-jdk

# Install Python and required tools
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    curl \
    wget \
    gnupg \
    ca-certificates \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install SBT - Using local file
COPY sbt-1.9.8.tgz /tmp/sbt.tgz
RUN tar xzf /tmp/sbt.tgz -C /usr/local && \
    ln -s /usr/local/sbt/bin/sbt /usr/bin/sbt && \
    rm /tmp/sbt.tgz && \
    sbt -Dsbt.rootdir=true version

# Set up PySpark
ENV SPARK_VERSION=3.5.5
ENV HADOOP_VERSION=3
ENV SPARK_HOME=/opt/spark
ENV PATH=$PATH:$SPARK_HOME/bin:$SPARK_HOME/sbin
ENV PYTHONPATH=$SPARK_HOME/python:$SPARK_HOME/python/lib/py4j-0.10.9.7-src.zip:$PYTHONPATH

# Download and install Spark
RUN wget -q https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/spark-${SPARK_VERSION}-bin-hadoop${HADOOP_VERSION}.tgz && \
    tar xzf spark-${SPARK_VERSION}-bin-hadoop${HADOOP_VERSION}.tgz && \
    mv spark-${SPARK_VERSION}-bin-hadoop${HADOOP_VERSION} ${SPARK_HOME} && \
    rm spark-${SPARK_VERSION}-bin-hadoop${HADOOP_VERSION}.tgz

# Set working directory
WORKDIR /app

# Copy project files
COPY build.sbt /app/
COPY project /app/project/
COPY src /app/src/

# Copy Python requirements
COPY requirements.txt /app/
RUN pip3 install --no-cache-dir --break-system-packages -r requirements.txt && \
    pip3 install --no-cache-dir --break-system-packages wheel setuptools build

# Build the JAR file
RUN sbt clean assembly

# Copy Python package
COPY python /app/python/

# Build Python wheel
RUN cd /app/python && python3 -m build --wheel

# Create output directory and copy artifacts
RUN mkdir -p /app/output && \
    cp /app/target/scala-2.12/*.jar /app/output/ && \
    cp /app/python/dist/*.whl /app/output/ && \
    ls -lh /app/output/

# Copy JDBC drivers
COPY lib /app/lib/

# Copy test scripts
COPY tests /app/tests/

CMD ["/bin/bash"]
