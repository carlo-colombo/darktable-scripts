--[[ 
-------------------------------------------------------------------------------- 
--
--  A LUA SCRIPT FOR DARKTABLE
--
--  AUTOMATED CLEANUP OF REJECTED IMAGES
--  Deletes images marked as "rejected" from the disk.
--
--  VERSION: 1.1.0
--  TICKET: DT-LUA-001
--
--  CHANGELOG:
--  - Fixed confirmation dialog implementation
--  - Fixed date format in log file
--  - Improved XMP sidecar detection
--  - Added proper error handling for database operations
--  - Enhanced file existence checking
--  - Added support for additional sidecar files
--  - Added progress feedback and statistics
--  - Improved error reporting consistency
--
-------------------------------------------------------------------------------- 
--]]

local dt = require "darktable"

-- Configuration
local CONFIG = {
  log_file_path = dt.configuration.config_dir .. "/deleted_images.log",
  sidecar_extensions = {".xmp", ".pp3", ".dop", ".pto"}, -- Common sidecar file extensions
}

-- Helper function to format file size
local function format_bytes(bytes)
  if bytes > 1024 * 1024 * 1024 then
    return string.format("%.2f GB", bytes / (1024 * 1024 * 1024))
  elseif bytes > 1024 * 1024 then
    return string.format("%.2f MB", bytes / (1024 * 1024))
  elseif bytes > 1024 then
    return string.format("%.2f KB", bytes / 1024)
  else
    return string.format("%d bytes", bytes)
  end
end

-- Helper function to get rejected images from the current collection
local function get_rejected_images()
  local rejected_images = {}
  local collection = dt.collection
  
  if not collection or #collection == 0 then
    dt.print_error("No images in the current collection.")
    return rejected_images
  end

  for _, image in ipairs(collection) do
    -- Validate image object before accessing rating
    if image and image.rating == -1 then
      table.insert(rejected_images, image)
    end
  end
  
  return rejected_images
end

-- Helper to get file size
local function get_file_size(path)
  local file = io.open(path, "rb")
  if not file then
    return 0
  end
  local size = file:seek("end")
  file:close()
  return size or 0
end

-- Helper to check if file exists
local function file_exists(path)
  local file = io.open(path, "r")
  if file then
    file:close()
    return true
  end
  return false
end

-- Helper to write to log
local function write_log(message)
  local file = io.open(CONFIG.log_file_path, "a")
  if file then
    -- Fixed: Use single % for date format
    file:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. message .. "\n")
    file:close()
  else
    dt.print_error("Could not open log file for writing: " .. CONFIG.log_file_path)
  end
end

-- Helper to get all sidecar files for an image
local function get_sidecar_files(image_path)
  local sidecars = {}
  local base_path = image_path:gsub("%.[^.]+$", "") -- Remove extension
  
  for _, ext in ipairs(CONFIG.sidecar_extensions) do
    local sidecar_path = base_path .. ext
    if file_exists(sidecar_path) then
      table.insert(sidecars, sidecar_path)
    end
  end
  
  return sidecars
end

-- AC 3: "Check Space" (Dry Run) functionality
local function check_space()
  local rejected_images = get_rejected_images()
  local file_count = #rejected_images

  if file_count == 0 then
    dt.print("No rejected images found in the current collection.")
    return
  end

  local total_size = 0
  local sidecar_count = 0
  
  for _, image in ipairs(rejected_images) do
    local image_path = image.path .. "/" .. image.filename
    total_size = total_size + get_file_size(image_path)
    
    -- Count and measure sidecar files
    local sidecars = get_sidecar_files(image_path)
    sidecar_count = sidecar_count + #sidecars
    for _, sidecar_path in ipairs(sidecars) do
      total_size = total_size + get_file_size(sidecar_path)
    end
  end

  local message = string.format(
    "Found %d rejected images (%d sidecar files).\nTotal space to be recovered: %s.",
    file_count,
    sidecar_count,
    format_bytes(total_size)
  )
  dt.print(message)
  write_log("Dry run: " .. message)
end

-- Perform the actual deletion
local function perform_deletion(rejected_images, file_count)
  local total_deleted_size = 0
  local deleted_files = {}
  local deleted_sidecars = {}
  local failed_deletions = {}
  local failed_sidecars = {}
  local failed_db_deletions = {}

  write_log("Starting deletion session for " .. file_count .. " images.")
  dt.print("Deleting images... please wait.")

  -- Process each image
  for i, image in ipairs(rejected_images) do
    local image_path = image.path .. "/" .. image.filename
    local file_size = get_file_size(image_path)

    -- Delete primary image file
    local success, err = os.remove(image_path)
    if success then
      total_deleted_size = total_deleted_size + file_size
      write_log("Deleted: " .. image_path)
      table.insert(deleted_files, image_path)

      -- Delete sidecar files
      local sidecars = get_sidecar_files(image_path)
      for _, sidecar_path in ipairs(sidecars) do
        local sidecar_size = get_file_size(sidecar_path)
        local sidecar_success = os.remove(sidecar_path)
        
        if sidecar_success then
          total_deleted_size = total_deleted_size + sidecar_size
          write_log("Deleted sidecar: " .. sidecar_path)
          table.insert(deleted_sidecars, sidecar_path)
        else
          write_log("ERROR: Failed to delete sidecar: " .. sidecar_path)
          table.insert(failed_sidecars, sidecar_path)
        end
      end

      -- Remove from database after successful file deletion
      -- In Darktable Lua API, images are removed by calling delete on the image itself
      local db_success, db_error = pcall(function()
        image:delete()
      end)

      if not db_success then
        write_log("ERROR: Database deletion failed for " .. image_path .. ": " .. tostring(db_error))
        table.insert(failed_db_deletions, image_path)
      end

    else
      write_log("ERROR: Failed to delete " .. image_path .. " - " .. tostring(err))
      table.insert(failed_deletions, image_path)
    end

    -- Show progress for large batches
    if i % 10 == 0 then
      dt.print(string.format("Progress: %d/%d images processed...", i, file_count))
    end
  end

  -- Generate summary
  local summary_message = string.format(
    "Deletion complete!\n" ..
    "Images deleted: %d/%d\n" ..
    "Sidecars deleted: %d\n" ..
    "Space recovered: %s",
    #deleted_files,
    file_count,
    #deleted_sidecars,
    format_bytes(total_deleted_size)
  )

  if #failed_deletions > 0 then
    summary_message = summary_message .. string.format(
      "\n\nWarning: %d files could not be deleted (check log for details)",
      #failed_deletions
    )
  end

  if #failed_sidecars > 0 then
    summary_message = summary_message .. string.format(
      "\nWarning: %d sidecar files could not be deleted",
      #failed_sidecars
    )
  end

  if #failed_db_deletions > 0 then
    summary_message = summary_message .. string.format(
      "\nWarning: %d images could not be removed from database",
      #failed_db_deletions
    )
  end

  write_log("End of session. " .. summary_message:gsub("\n", " "))
  dt.print(summary_message)
end

-- State variables
local confirmation_checkbox = nil
local deletion_in_progress = false

-- AC 4 & 5: "Delete Permanently" functionality
local function delete_permanently()
  -- Prevent concurrent executions
  if deletion_in_progress then
    dt.print("Deletion already in progress. Please wait...")
    return
  end

  local rejected_images = get_rejected_images()
  local file_count = #rejected_images

  if file_count == 0 then
    dt.print("No rejected images to delete.")
    return
  end

  -- Check if confirmation checkbox is checked
  if not confirmation_checkbox or not confirmation_checkbox.value then
    dt.print_error("Please check the confirmation box above to enable deletion.")
    write_log("Deletion attempt without confirmation checkbox - blocked")
    return
  end

  -- Set flag to prevent re-entry
  deletion_in_progress = true

  -- Proceed with deletion
  dt.print(string.format("Starting deletion of %d rejected images...", file_count))
  write_log(string.format("User confirmed deletion of %d images", file_count))
  
  perform_deletion(rejected_images, file_count)
  
  -- Clear the confirmation checkbox and reset flag
  confirmation_checkbox.value = false
  deletion_in_progress = false
end

-- Helper to get collection info
local function get_collection_info()
  local collection = dt.collection
  if not collection then
    return "No collection"
  end
  
  local count = #collection
  local rejected_count = 0
  
  for _, image in ipairs(collection) do
    if image and image.rating == -1 then
      rejected_count = rejected_count + 1
    end
  end
  
  return string.format("%d images (%d rejected)", count, rejected_count)
end

-- AC 1 & 6: Register the library module
confirmation_checkbox = dt.new_widget("check_button")({
  label = "I understand this will permanently delete files",
  value = false,
  tooltip = "Check this box to confirm you want to delete rejected images permanently from disk.",
  clicked_callback = function(widget)
    if widget.value then
      dt.print("Deletion enabled. Click 'Delete Permanently' to proceed.")
    end
  end,
})

local collection_label = dt.new_widget("label")({
  label = "Collection: " .. get_collection_info(),
  ellipsize = "middle",
})

-- Update collection info when mouse enters the module
local function update_collection_info()
  pcall(function()
    collection_label.label = "Collection: " .. get_collection_info()
  end)
end

local box = dt.new_widget("box")({
  orientation = "vertical",
  dt.new_widget("label")({ 
    label = "Rejected Image Cleanup",
    ellipsize = "none",
  }),
  collection_label,
  dt.new_widget("button")({
    label = "Refresh Collection Info",
    tooltip = "Update the collection statistics",
    clicked_callback = update_collection_info,
  }),
  dt.new_widget("section_label")({ label = "Actions:" }),
  dt.new_widget("button")({
    label = "Check Space (Dry Run)",
    tooltip = "Calculate space used by rejected images without deleting them.",
    clicked_callback = check_space,
  }),
  dt.new_widget("separator")({}),
  dt.new_widget("label")({
    label = "⚠ WARNING: Permanent Deletion ⚠",
    ellipsize = "none",
  }),
  confirmation_checkbox,
  dt.new_widget("button")({
    label = "Delete Permanently",
    tooltip = "Permanently delete all rejected images in the current collection from disk. Requires confirmation checkbox above.",
    clicked_callback = delete_permanently,
  }),
  dt.new_widget("separator")({}),
  dt.new_widget("section_label")({ label = "Info:" }),
  dt.new_widget("label")({ 
    label = "Log: " .. CONFIG.log_file_path,
    ellipsize = "middle",
  }),
})

dt.register_lib(
  "delete_rejected",
  "Delete Rejected",
  true,
  false,
  -- Display order: 100 (moderate priority in right panel)
  {[dt.gui.views.lighttable] = {"DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100}},
  box
)

-- Show function to make module visible
local function show()
  if dt.gui.libs.delete_rejected then
    dt.gui.libs.delete_rejected.visible = true
  end
end

-- Cleanup function for proper module unregistration
local function destroy()
  -- Nothing to clean up for the main module
end

-- Script metadata
local script_data = {}
script_data.destroy = destroy
script_data.restart = nil
script_data.show = show

-- Make the module visible on startup
show()

write_log("Script initialized successfully (v1.1.0)")

return script_data