import 'dart:convert';
import 'dart:typed_data';

// Real 1x1 images encoded by Pillow, kept outside production classes.
final Uint8List tinyMangaPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGOQq7gEAAIgAWmLr1EG'
  'AAAAAElFTkSuQmCC',
);

final Uint8List tinyMangaJpeg = base64Decode(
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a'
  'HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIy'
  'MjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIA'
  'AhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQA'
  'AAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3'
  'ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWm'
  'p6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEA'
  'AwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSEx'
  'BhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElK'
  'U1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3'
  'uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDGooor'
  '7U+RP//Z',
);

final Uint8List tinyMangaWebp = base64Decode(
  'UklGRjoAAABXRUJQVlA4IC4AAAAQAgCdASoBAAEAAUAmJaACdLoB+AH4AAPIAP7tBy/9WfTQi/vX'
  '//Rg3+UXyxgA',
);

final Uint8List tinyMangaGif87a = base64Decode(
  'R0lGODdhAQABAIEAAB540gAAAAAAAAAAACwAAAAAAQABAAAIBAABBAQAOw==',
);

final Uint8List tinyMangaAvif = base64Decode(
  'AAAAIGZ0eXBhdmlmAAAAAGF2aWZtaWYxbWlhZk1BMUIAAADrbWV0YQAAAAAAAAAhaGRscgAAAAAA'
  'AAAAcGljdAAAAAAAAAAAAAAAAAAAAAAOcGl0bQAAAAAAAQAAAB5pbG9jAAAAAEQAAAEAAQAAAAEA'
  'AAETAAAAKQAAAChpaW5mAAAAAAABAAAAGmluZmUCAAAAAAEAAGF2MDFDb2xvcgAAAABqaXBycAAA'
  'AEtpcGNvAAAAFGlzcGUAAAAAAAAAAQAAAAEAAAAQcGl4aQAAAAADCAgIAAAADGF2MUOBAAwAAAAA'
  'E2NvbHJuY2x4AAEADQAGgAAAABdpcG1hAAAAAAAAAAEAAQQBAoMEAAAAMW1kYXQSAAoIGAAGiAho'
  'NCAyGxTHh4ZlAgggnlAAAABIWtlc1jNRcyldqnssGA==',
);

final Uint8List tinyMangaGif89a = Uint8List.fromList(tinyMangaGif87a)
  ..setRange(3, 6, ascii.encode('89a'));

final Map<String, Uint8List> tinyMangaImages = <String, Uint8List>{
  'png': tinyMangaPng,
  'jpeg': tinyMangaJpeg,
  'webp': tinyMangaWebp,
  'gif87a': tinyMangaGif87a,
  'gif89a': tinyMangaGif89a,
  'avif': tinyMangaAvif,
};
