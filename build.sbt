name := "spark-jdbc-writer"
version := "1.0.7"
scalaVersion := "2.12.18"

libraryDependencies ++= Seq(
  "org.apache.spark" %% "spark-sql" % "3.5.5" % "provided",
  "org.apache.spark" %% "spark-catalyst" % "3.5.5" % "provided",

  // Logging (provided by Spark runtime)
  "org.slf4j" % "slf4j-api" % "2.0.9" % "provided",
  "com.typesafe.scala-logging" %% "scala-logging" % "3.9.5",

  // JDBC drivers (included in assembly JAR)
  "org.postgresql" % "postgresql" % "42.7.3",
  "com.oracle.database.jdbc" % "ojdbc11" % "23.3.0.23.09" % "optional",

  // Testing
  "org.scalatest" %% "scalatest" % "3.2.18" % "test",
  "com.h2database" % "h2" % "2.2.224" % "test"
)

// Assembly settings for fat JAR
assembly / assemblyMergeStrategy := {
  case PathList("META-INF", xs @ _*) => MergeStrategy.discard
  case x => MergeStrategy.first
}
