// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'pending_request.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class PendingRequestAdapter extends TypeAdapter<PendingRequest> {
  @override
  final int typeId = 0;

  @override
  PendingRequest read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PendingRequest(
      id: fields[0] as String,
      method: fields[1] as String,
      url: fields[2] as String,
      headers: (fields[3] as Map).cast<String, String?>(),
      body: (fields[4] as Map).cast<String, dynamic>(),
      retryCount: fields[5] as int,
      createdAt: fields[6] as DateTime,
      dedupHash: fields[7] as String,
      priority: fields[8] as int,
      expiresAtMs: fields[9] as int?,
    );
  }

  @override
  void write(BinaryWriter writer, PendingRequest obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.method)
      ..writeByte(2)
      ..write(obj.url)
      ..writeByte(3)
      ..write(obj.headers)
      ..writeByte(4)
      ..write(obj.body)
      ..writeByte(5)
      ..write(obj.retryCount)
      ..writeByte(6)
      ..write(obj.createdAt)
      ..writeByte(7)
      ..write(obj.dedupHash)
      ..writeByte(8)
      ..write(obj.priority)
      ..writeByte(9)
      ..write(obj.expiresAtMs);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PendingRequestAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
