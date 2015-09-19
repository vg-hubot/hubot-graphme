# Description:
#   Render graphite graphs
#
# Dependencies:
#   None
#
# Configuration:
#   HUBOT_GRAPHITE_URL                  - Location where graphite web interface can be found (e.g., "https://graphite.domain.com")
#   HUBOT_GRAPHITE_S3_BUCKET            - Amazon S3 bucket where graph snapshots will be stored
#   HUBOT_GRAPHITE_S3_ACCESS_KEY_ID     - Amazon S3 access key ID for snapshot storage
#   HUBOT_GRAPHITE_S3_SECRET_ACCESS_KEY - Amazon S3 secret access key for snapshot storage
#   HUBOT_GRAPHITE_S3_REGION            - Amazon S3 region (default: "us-east-1")
#   HUBOT_GRAPHITE_S3_IMAGE_PATH        - Subdirectory in which to store S3 snapshots (default: "hubot-graphme")
#
# Commands:
#   hubot graph me vmpooler.running.*                                    - show a graph for a graphite query using a target
#   hubot graph me -1h vmpooler.running.*                                - show a graphite graph with a target and a from time
#   hubot graph me -6h..-1h vmpooler.running.*                           - show a graphite graph with a target and a time range
#   hubot graph me -6h..-1h foo.bar.baz + summarize(bar.baz.foo,"1day")  - show a graphite graph with multiple targets
#
# Author:
#   Rick Bradley (rick@rickbradley.com, github.com/rick)

crypto  = require "crypto"
knox    = require "knox"
request = require "request"

module.exports = (robot) ->

  notConfigured = () ->
    result = []
    result.push "HUBOT_GRAPHITE_URL" unless process.env["HUBOT_GRAPHITE_URL"]
    result.push "HUBOT_GRAPHITE_S3_BUCKET" unless process.env["HUBOT_GRAPHITE_S3_BUCKET"]
    result.push "HUBOT_GRAPHITE_S3_ACCESS_KEY_ID" unless process.env["HUBOT_GRAPHITE_S3_ACCESS_KEY_ID"]
    result.push "HUBOT_GRAPHITE_S3_SECRET_ACCESS_KEY" unless process.env["HUBOT_GRAPHITE_S3_SECRET_ACCESS_KEY"]
    result

  isConfigured = () ->
    notConfigured().length == 0

  config = {
      bucket          : process.env["HUBOT_GRAPHITE_S3_BUCKET"],
      accessKeyId     : process.env["HUBOT_GRAPHITE_S3_ACCESS_KEY_ID"],
      secretAccessKey : process.env["HUBOT_GRAPHITE_S3_SECRET_ACCESS_KEY"],
      imagePath       : imagePathConfig
      region          : process.env["HUBOT_GRAPHITE_S3_REGION"] || "us-east-1"
    }

  AWSCredentials = {
      accessKeyId     : config["accessKeyId"]
      secretAccessKey : config["secretAccessKey"]
      region          : config["region"]
    }

  imagePathConfig = () ->
    return "hubot-graphme" unless process.env["HUBOT_GRAPHITE_S3_IMAGE_PATH"]
    process.env["HUBOT_GRAPHITE_S3_IMAGE_PATH"].replace(/\/+$/, "")

  uploadFolder = () ->
    (config["imagePath"] == "" ? "hubot-graphme" : config["imagePath"]) + "/"

  # pick a random filename
  uploadPath = () ->
    "#{uploadFolder}/#{crypto.randomBytes(20).toString("hex")}.png"

  imgURL = (filename) ->
    "https://s3.amazonaws.com/#{config["bucket"]}/#{filename}"

  # Fetch an image from provided URL, upload it to S3, returning the resulting URL
  fetchAndUpload = (msg, url) ->
    request url, { encoding: null }, (err, response, body) ->
      if typeof body isnt "undefined" # hacky
        console.log "Uploading file: #{body.length} bytes, content-type[#{response.headers["content-type"]}]"
        uploadToS3(msg, body, body.length, response.headers["content-type"])
      else
        # error handling

  uploadClient = () ->
    knox.createClient {
      key    : AWSCredentials["accessKeyId"],
      secret : AWSCredentials["secretAccessKey"],
      bucket : config["bucket"]
    }

  buildUploadRequest = (length, content_type) ->
    client = uploadClient()
    filename = uploadPath()
    headers = {
      "Content-Length" : length,
      "Content-Type"   : content_type,
      "x-amz-acl"      : "public-read",
      "encoding"       : null
    }
    client.put(filename, headers)

  uploadToS3 = (msg, content, length, content_type) ->
    req = buildUploadRequest(length, content_type)
    req.on "response", (res) ->
      if (200 == res.statusCode)
        return msg.reply imgURL(filename)
    req.end(content);


  #
  #  build robot grammar regex
  #

  timePattern = "(?:[-_:\/+a-zA-Z0-9]+)"

  robot.respond ///
    graph(?:\s+me)?                       # graph me

    (?:                                   # optional time range
      (?:\s+
        (#{timePattern})                  # \1 - capture (from)
        (?:
        \.\.\.?                              # from..through range
          (#{timePattern})                # \2 - capture (until)
        )?
      )?

      (?:\s+                              # graphite targets
        (                                 # \3 - capture
          \S+                             # a graphite target
          (?:\s+\+\s+                     # " + "
            \S+                           # more graphite targets
          )*
        )
      )
    )?                                    # time + target is also optional
  ///, (msg) ->

    if isConfigured()
      url = process.env["HUBOT_GRAPHITE_URL"].replace(/\/+$/, "") # drop trailing "/"s
      from    = msg.match[1]
      through = msg.match[2]
      targets  = msg.match[3]

      result = []

      if targets
        targets.split(/\s+\+\s+/).map (target) ->
          result.push "target=#{encodeURIComponent(target)}"

        if from?
          from += "in" if from.match /\d+m$/ # -1m -> -1min
          result.push "from=#{encodeURIComponent(from)}"

          if through?
            through += "in" if through.match /\d+m$/ # -1m -> -1min
            result.push "until=#{encodeURIComponent(through)}"

        result.push "format=png"
        graphiteURL = "#{url}/render?#{result.join("&")}"

        msg.reply graphiteURL
        fetchAndUpload(msg, graphiteURL)
      else
        msg.reply "Type: `help graph` for usage info"
    else
      msg.send "Configuration variables are not set: #{notConfigured().join(", ")}."
