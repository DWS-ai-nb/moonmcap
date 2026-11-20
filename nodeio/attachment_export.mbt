///|
#external
#warnings("-missing_priv")
type AttachmentExportDirectory

///|
extern "js" fn open_export_directory(
  directory : String,
) -> AttachmentExportDirectory =
  #| directory => {
  #|   const fs = process.getBuiltinModule("node:fs");
  #|   const path = process.getBuiltinModule("node:path");
  #|   try {
  #|     const requested = path.resolve(directory);
  #|     const canonical = fs.realpathSync(requested);
  #|     const stat = fs.statSync(canonical, { bigint: true });
  #|     if (!stat.isDirectory()) throw new Error("attachment export parent is not a directory");
  #|     return { requested, canonical, key: String(stat.dev) + "|" + String(stat.ino), error: "" };
  #|   } catch (error) {
  #|     return { error: error.message };
  #|   }
  #| }

///|
extern "js" fn export_directory_error(
  directory : AttachmentExportDirectory,
) -> String =
  #| directory => directory.error

///|
extern "js" fn check_export_directory(
  directory : AttachmentExportDirectory,
) -> String =
  #| directory => {
  #|   try {
  #|     const fs = process.getBuiltinModule("node:fs");
  #|     if (fs.realpathSync(directory.requested) !== directory.canonical) {
  #|       throw new Error("attachment export directory changed");
  #|     }
  #|     const stat = fs.statSync(directory.canonical, { bigint: true });
  #|     if (!stat.isDirectory() || String(stat.dev) + "|" + String(stat.ino) !== directory.key) {
  #|       throw new Error("attachment export directory identity changed");
  #|     }
  #|     return "";
  #|   } catch (error) {
  #|     return error.message;
  #|   }
  #| }

///|
extern "js" fn export_target_path(
  directory : AttachmentExportDirectory,
  prefix : String,
  offset : String,
) -> String =
  #| (directory, prefix, offset) => {
  #|   const path = process.getBuiltinModule("node:path");
  #|   return path.join(directory.canonical, prefix + "-" + offset + ".bin");
  #| }

///|
extern "js" fn export_target_absent(target : String) -> String =
  #| target => {
  #|   const fs = process.getBuiltinModule("node:fs");
  #|   try {
  #|     fs.lstatSync(target);
  #|     return "attachment export target already exists";
  #|   } catch (error) {
  #|     return error.code === "ENOENT" ? "" : error.message;
  #|   }
  #| }

///|
pub struct NodeAttachmentExportPlan {
  plan : @mcap.AttachmentExportPlan
  directory : AttachmentExportDirectory
}

///|
fn check_attachment_prefix(prefix : String) -> Unit raise @mcap.McapError {
  if prefix.length() < 1 || prefix.length() > 64 {
    raise @mcap.io_error(
      "attachment export prefix must contain 1..64 ASCII characters",
    )
  }
  for char in prefix {
    if !(char >= 'a' && char <= 'z') &&
      !(char >= 'A' && char <= 'Z') &&
      !(char >= '0' && char <= '9') &&
      char != '-' &&
      char != '_' {
      raise @mcap.io_error(
        "attachment export prefix accepts ASCII letters, digits, hyphen, underscore",
      )
    }
  }
}

///|
fn require_export_directory(
  directory : AttachmentExportDirectory,
) -> Unit raise @mcap.McapError {
  let error = check_export_directory(directory)
  if error != "" {
    raise @mcap.io_error(error)
  }
}

///|
/// Plan binary exports into one existing directory. Filenames contain the
/// source's physical record offset; original attachment names stay in receipts.
pub fn attachment_export_plan(
  selection : @mcap.AttachmentSelection,
  directory : String,
  prefix~ : String = "attachment",
  cancelled~ : () -> Bool = fn() { false },
) -> NodeAttachmentExportPlan raise @mcap.McapError {
  check_attachment_prefix(prefix)
  let native = open_export_directory(directory)
  let error = export_directory_error(native)
  if error != "" {
    raise @mcap.io_error(error)
  }
  let plan = selection.plan_exports(
    info => export_target_path(native, prefix, info.offset.to_string()),
    cancelled~,
  )
  require_export_directory(native)
  { plan, directory: native, }
}

///|
pub fn NodeAttachmentExportPlan::info(
  self : NodeAttachmentExportPlan,
) -> @mcap.AttachmentExportPlanInfo {
  self.plan.info()
}

///|
pub fn NodeAttachmentExportPlan::targets(
  self : NodeAttachmentExportPlan,
) -> Array[(String, @mcap.AttachmentIndex)] {
  self.plan.targets()
}

///|
/// Preflight the current batch before opening any output, then publish one
/// checked attachment at a time. on_published can persist completion receipts.
/// A later failure retains earlier successful publications.
pub fn NodeAttachmentExportPlan::export_files(
  self : NodeAttachmentExportPlan,
  start_index~ : Int32 = 0,
  max_files~ : Int32 = 1000,
  on_published~ : (@mcap.AttachmentExportReceipt) -> Unit raise @mcap.McapError = fn(
    _,
  ) {
    ()
  },
  cancelled~ : () -> Bool = fn() { false },
) -> @mcap.AttachmentExportReport raise @mcap.McapError {
  let targets = self.plan.targets()
  if start_index < 0 || start_index > targets.length() || max_files <= 0 {
    raise @mcap.io_error("invalid attachment file export continuation")
  }
  require_export_directory(self.directory)
  let count = max_files.min(targets.length() - start_index)
  for index in start_index..<(start_index + count) {
    if cancelled() {
      raise @mcap.io_error("attachment export cancelled")
    }
    let error = export_target_absent(targets[index].0)
    if error != "" {
      raise @mcap.io_error("\{error}: \{targets[index].0}")
    }
  }
  self.plan.export_files(
    (destination, _) => {
      require_export_directory(self.directory)
      let transaction = output_transaction(destination)
      @mcap.attachment_export_destination(
        transaction.sink(),
        () => {
          require_export_directory(self.directory)
          transaction.publish()
        },
        () => transaction.abort(),
      )
    },
    start_index~,
    max_files~,
    on_published~,
    cancelled~,
  )
}

///|
pub fn export_attachments(
  selection : @mcap.AttachmentSelection,
  directory : String,
  prefix~ : String = "attachment",
  start_index~ : Int32 = 0,
  max_files~ : Int32 = 1000,
  on_published~ : (@mcap.AttachmentExportReceipt) -> Unit raise @mcap.McapError = fn(
    _,
  ) {
    ()
  },
  cancelled~ : () -> Bool = fn() { false },
) -> @mcap.AttachmentExportReport raise @mcap.McapError {
  attachment_export_plan(selection, directory, prefix~, cancelled~).export_files(
    start_index~,
    max_files~,
    on_published~,
    cancelled~,
  )
}
