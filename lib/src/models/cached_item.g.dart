// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'cached_item.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CachedItemAdapter extends TypeAdapter<CachedItem> {
  @override
  final int typeId = 1;

  @override
  CachedItem read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CachedItem(
      key: fields[0] as String,
      data: fields[1] as dynamic,
      ttlSeconds: fields[2] as int,
      cachedAt: fields[3] as DateTime?,
      tags: (fields[4] as List).cast<String>(),
      etag: fields[5] as String?,
      lastModified: fields[6] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, CachedItem obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.key)
      ..writeByte(1)
      ..write(obj.data)
      ..writeByte(2)
      ..write(obj.ttlSeconds)
      ..writeByte(3)
      ..write(obj.cachedAt)
      ..writeByte(4)
      ..write(obj.tags)
      ..writeByte(5)
      ..write(obj.etag)
      ..writeByte(6)
      ..write(obj.lastModified);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CachedItemAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class DeadLetterRequestAdapter extends TypeAdapter<DeadLetterRequest> {
  @override
  final int typeId = 2;

  @override
  DeadLetterRequest read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return DeadLetterRequest(
      id: fields[0] as String,
      original: fields[1] as PendingRequest,
      failureReason: fields[2] as String,
      failedAt: fields[3] as DateTime,
      totalAttempts: fields[4] as int,
    );
  }

  @override
  void write(BinaryWriter writer, DeadLetterRequest obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.original)
      ..writeByte(2)
      ..write(obj.failureReason)
      ..writeByte(3)
      ..write(obj.failedAt)
      ..writeByte(4)
      ..write(obj.totalAttempts);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeadLetterRequestAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
