require "pg"

module Invidious::Database
  extend self

  def check_enum(db, enum_name, struct_type = nil)
    return # TODO

    if !db.query_one?("SELECT true FROM pg_type WHERE typname = $1", enum_name, as: Bool)
      LOGGER.info("check_enum: CREATE TYPE #{enum_name}")

      db.using_connection do |conn|
        conn.as(PG::Connection).exec_all(File.read("config/sql/#{enum_name}.sql"))
      end
    end
  end

  def check_table(db, table_name, struct_type = nil)
    # Create table if it doesn't exist
    begin
      db.exec("SELECT * FROM #{table_name} LIMIT 0")
    rescue ex
      LOGGER.info("check_table: check_table: CREATE TABLE #{table_name}")

      db.using_connection do |conn|
        conn.as(PG::Connection).exec_all(File.read("config/sql/#{table_name}.sql"))
      end
    end

    return if !struct_type

    struct_array = struct_type.type_array
    column_array = get_column_array(db, table_name)
    column_types = File.read("config/sql/#{table_name}.sql").match(/CREATE TABLE public\.#{table_name}\n\((?<types>[\d\D]*?)\);/)
      .try &.["types"].split(",").map(&.strip).reject &.starts_with?("CONSTRAINT")

    return if !column_types

    struct_array.each_with_index do |name, i|
      if name != column_array[i]?
        if !column_array[i]?
          new_column = column_types.select(&.starts_with?(name))[0]
          LOGGER.info("check_table: ALTER TABLE #{table_name} ADD COLUMN #{new_column}")
          db.exec("ALTER TABLE #{table_name} ADD COLUMN #{new_column}")
          next
        end

        # Column doesn't exist
        if !column_array.includes? name
          new_column = column_types.select(&.starts_with?(name))[0]
          db.exec("ALTER TABLE #{table_name} ADD COLUMN #{new_column}")
        end

        # Column exists but in the wrong position, rotate
        if struct_array.includes? column_array[i]
          until name == column_array[i]
            new_column = column_types.select(&.starts_with?(column_array[i]))[0]?.try &.gsub("#{column_array[i]}", "#{column_array[i]}_new")

            # There's a column we didn't expect
            if !new_column
              LOGGER.info("check_table: ALTER TABLE #{table_name} DROP COLUMN #{column_array[i]}")
              db.exec("ALTER TABLE #{table_name} DROP COLUMN #{column_array[i]} CASCADE")

              column_array = get_column_array(db, table_name)
              next
            end

            LOGGER.info("check_table: ALTER TABLE #{table_name} ADD COLUMN #{new_column}")
            db.exec("ALTER TABLE #{table_name} ADD COLUMN #{new_column}")

            LOGGER.info("check_table: UPDATE #{table_name} SET #{column_array[i]}_new=#{column_array[i]}")
            db.exec("UPDATE #{table_name} SET #{column_array[i]}_new=#{column_array[i]}")

            LOGGER.info("check_table: ALTER TABLE #{table_name} DROP COLUMN #{column_array[i]} CASCADE")
            db.exec("ALTER TABLE #{table_name} DROP COLUMN #{column_array[i]} CASCADE")

            LOGGER.info("check_table: ALTER TABLE #{table_name} RENAME COLUMN #{column_array[i]}_new TO #{column_array[i]}")
            db.exec("ALTER TABLE #{table_name} RENAME COLUMN #{column_array[i]}_new TO #{column_array[i]}")

            column_array = get_column_array(db, table_name)
          end
        else
          LOGGER.info("check_table: ALTER TABLE #{table_name} DROP COLUMN #{column_array[i]} CASCADE")
          db.exec("ALTER TABLE #{table_name} DROP COLUMN #{column_array[i]} CASCADE")
        end
      end
    end

    return if column_array.size <= struct_array.size

    column_array.each do |column|
      if !struct_array.includes? column
        LOGGER.info("check_table: ALTER TABLE #{table_name} DROP COLUMN #{column} CASCADE")
        db.exec("ALTER TABLE #{table_name} DROP COLUMN #{column} CASCADE")
      end
    end
  end

  def get_column_array(db, table_name)
    column_array = [] of String
    db.query("SELECT * FROM #{table_name} LIMIT 0") do |rs|
      rs.column_count.times do |i|
        column = rs.as(PG::ResultSet).field(i)
        column_array << column.name
      end
    end

    return column_array
  end
end
