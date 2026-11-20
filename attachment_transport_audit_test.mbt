///|
test "cancellation inside an attachment source stops the stream writer" {
  let out = @buffer.Buffer::Buffer()
  let writer = @moonmcap.new_stream_writer(
    @moonmcap.new_write_sink(bytes => out.write_bytes(bytes[:])),
  )
  let mut calls = 0
  let source = @moonmcap.new_read_source(70000UL, (_, length) => {
    calls += 1
    writer.cancel()
    Bytes::make(length, 7)
  })
  try
    writer.add_attachment_from(
      source, "cancelled.bin", "application/octet-stream",
    )
  catch {
    @moonmcap.Invalid(_) => ()
  } noraise {
    _ => fail("cancellation during source callback must interrupt the transfer")
  }
  assert_eq(calls, 1)
  assert_eq(writer.progress().state, @moonmcap.WriterCancelled)
  try ignore(writer.finish()) catch {
    @moonmcap.Invalid(_) => ()
  } noraise {
    _ => fail("cancelled writer cannot publish a completed footer")
  }
}

///|
test "attachment copy supports CRC absent and empty payload" {
  let log = {
    ..@moonmcap.empty_log(),
    attachments: [
      {
        log_time: 0UL,
        create_time: 0UL,
        name: "empty",
        media_type: "application/octet-stream",
        data: b"",
      },
    ],
  }
  let recording = @moonmcap.write_log(log, checksums=false)
  let reader = @moonmcap.open_reader(@moonmcap.memory_source(recording))
  let found = []
  reader.visit_attachments(item => {
    found.push(item)
    true
  })
  assert_eq(found.length(), 1)
  let written = @buffer.Buffer::Buffer()
  assert_false(
    found[0].copy_to(
      @moonmcap.new_write_sink(bytes => written.write_bytes(bytes[:])),
    ),
  )
  assert_eq(written.length(), 0)
}

///|
test "short-read attachment sources preserve exact payload and CRC" {
  let output = @buffer.Buffer::Buffer()
  let writer = @moonmcap.new_stream_writer(
    @moonmcap.new_write_sink(bytes => output.write_bytes(bytes[:])),
  )
  let payload = Bytes::makei(131079, index => (index % 251).to_byte())
  let mut input_reads = 0
  let source = @moonmcap.new_read_source(payload.length().to_uint64(), (
    offset,
    length,
  ) => {
    input_reads += 1
    let start = offset.to_int()
    payload[start:start + length.min(97)].to_owned()
  })
  writer.add_attachment_from(
    source, "short-read.bin", "application/octet-stream",
  )
  ignore(writer.finish())
  assert_true(input_reads > 1000)
  let reader = @moonmcap.open_reader(@moonmcap.memory_source(output.to_bytes()))
  let found = []
  reader.visit_attachments(item => {
    found.push(item)
    true
  })
  let extracted = @buffer.Buffer::Buffer()
  assert_true(
    found[0].copy_to(
      @moonmcap.new_write_sink(bytes => extracted.write_bytes(bytes[:])),
    ),
  )
  assert_eq(extracted.to_bytes(), payload)
}

///|
test "attachment payload IO failures poison the writer and preserve input error" {
  let writer = @moonmcap.new_stream_writer(
    @moonmcap.new_write_sink(fn(_) { () }),
  )
  let source = @moonmcap.new_read_source(131072UL, (offset, length) => {
    if offset != 0UL {
      raise @moonmcap.io_error("source device disconnected")
    }
    Bytes::make(length, 3)
  })
  try
    writer.add_attachment_from(source, "failed.bin", "application/octet-stream")
  catch {
    @moonmcap.Invalid(reason) =>
      assert_true(reason.contains("source device disconnected"))
  } noraise {
    _ => fail("source failure should propagate")
  }
  assert_eq(writer.progress().state, @moonmcap.WriterFailed)
}

///|
test "sink cancellation while flushing pending messages stops further writes" {
  let cancel = [false]
  let owner : Array[@moonmcap.StreamWriter] = []
  let mut calls = 0
  let writer = @moonmcap.new_stream_writer(
    @moonmcap.new_write_sink(bytes => {
      ignore(bytes)
      calls += 1
      if cancel[0] {
        owner[0].cancel()
      }
    }),
  )
  owner.push(writer)
  writer.add_channel({
    id: 1,
    schema_id: 0,
    topic: "/test",
    message_encoding: "raw",
    metadata: [],
  })
  writer.append({
    channel_id: 1,
    sequence: 0U,
    log_time: 1UL,
    publish_time: 1UL,
    data: b"pending",
  })
  let before = calls
  cancel[0] = true
  try
    writer.add_attachment_from(
      @moonmcap.memory_source(b"payload"),
      "cancelled",
      "raw",
    )
  catch {
    @moonmcap.Invalid(_) => ()
  } noraise {
    _ =>
      fail(
        "sink cancellation while flushing must interrupt attachment creation",
      )
  }
  assert_eq(calls, before + 1)
  assert_eq(writer.progress().state, @moonmcap.WriterCancelled)
}
