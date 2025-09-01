# 手順書

## Amazon Linux 2 での環境構築

### Vim のインストール
```bash
sudo yum install vim -y
```

`.vimrc` を開いて以下を記述:
```vim
set number
set expandtab
set tabstop=2
set shiftwidth=2
set autoindent
```

---

### Screen のインストール
```bash
sudo yum install screen -y
screen
```

`.screenrc` の内容:
```bash
hardstatus alwayslastline "%{= bw}%-w%{= wk}%n%t*%{-}%+w"
```

---

### Docker のインストール
```bash
sudo yum install -y docker
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -a -G docker ec2-user
```

---

### Docker Compose のインストール
```bash
sudo mkdir -p /usr/local/lib/docker/cli-plugins/
sudo curl -SL https://github.com/docker/compose/releases/download/v2.36.0/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
```

---

## プロジェクトの準備

### ディレクトリ作成
```bash
mkdir dockertest
cd dockertest
```

### docker-compose 設定ファイル
`compose.yml`
```yaml
services:
  web:
    image: nginx:latest
    ports:
      - 80:80
    volumes:
      - ./nginx/conf.d/:/etc/nginx/conf.d/
      - ./public/:/var/www/public/
      - image:/var/www/upload/image/
    depends_on:
      - php

  php:
    container_name: php
    build:
      context: .
      target: php
    volumes:
      - ./public/:/var/www/public/
      - image:/var/www/upload/image/

  mysql:
    container_name: mysql
    image: mysql:8.4
    environment:
      MYSQL_DATABASE: example_db
      MYSQL_ALLOW_EMPTY_PASSWORD: 1
      TZ: Asia/Tokyo
    volumes:
      - mysql:/var/lib/mysql
    command: >
      mysqld
      --character-set-server=utf8mb4
      --collation-server=utf8mb4_unicode_ci
      --max_allowed_packet=4MB

volumes:
  mysql:
  image:
```

---

## Nginx の設定

### ディレクトリ作成
```bash
mkdir nginx
mkdir nginx/conf.d
```

### 設定ファイル
`nginx/conf.d/default.conf`
```nginx
server {
    listen       0.0.0.0:80;
    server_name  _;
    charset      utf-8;

    root /var/www/public;

    location ~ \.php$ {
        fastcgi_pass  php:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME  $document_root$fastcgi_script_name;
        include       fastcgi_params;
    }

    location /image/ {
        root /var/www/upload;
    }
}
```

---

## PHP ファイル作成

### ディレクトリ作成
```bash
mkdir public
```

### 掲示板アプリ
`public/kadai.php`
```php
<?php
// ===== ここより前に空白/改行/文字を絶対に置かない（BOMなしUTF-8で保存）=====

// ===== DB接続 =====
$dsn = 'mysql:host=mysql;dbname=example_db;charset=utf8mb4';
$user = 'root';
$pass = '';
$options = [
  PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
  PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
];
$dbh = new PDO($dsn, $user, $pass, $options);

// ===== セキュリティヘッダ（必ず出力前に）=====
header("X-Content-Type-Options: nosniff");
header("Referrer-Policy: no-referrer-when-downgrade");
header("Content-Security-Policy: default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline';");

// ===== 画像保存先（実ディスク）=====
$UPLOAD_DIR = '/var/www/upload/image';
if (!is_dir($UPLOAD_DIR)) {
  mkdir($UPLOAD_DIR, 0755, true);
}

// ===== MIME→拡張子の安全マップ =====
function ext_from_mime(string $mime): ?string {
  static $map = [
    'image/jpeg' => 'jpg',
    'image/png'  => 'png',
    'image/gif'  => 'gif',
    'image/webp' => 'webp',
  ];
  $mime = strtolower($mime);
  return $map[$mime] ?? null;
}

// ===== MIME判定 =====
function detect_mime(string $tmpPath): ?string {
  if (class_exists('finfo')) {
    $finfo = new finfo(FILEINFO_MIME_TYPE);
    return $finfo->file($tmpPath) ?: null;
  }
  if (function_exists('mime_content_type')) {
    return @mime_content_type($tmpPath) ?: null;
  }
  return null;
}

// ===== POST（新規投稿）=====
if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['body'])) {
  $body = trim($_POST['body']);

  // 本文バリデーション
  if ($body === '' || mb_strlen($body) > 2000) {
    header('HTTP/1.1 302 Found');
    header('Location: ./kadai.php?err=body');
    exit;
  }

  $image_filename = null;

  // 画像が来ていれば検証
  if (isset($_FILES['image']) && is_uploaded_file($_FILES['image']['tmp_name'])) {
    $max = 5 * 1024 * 1024; // 5MB
    if ($_FILES['image']['size'] > $max) {
      header('HTTP/1.1 302 Found');
      header('Location: ./kadai.php?err=size');
      exit;
    }

    $mime = detect_mime($_FILES['image']['tmp_name']);
    $ext  = $mime ? ext_from_mime($mime) : null;
    if ($ext === null) {
      header('HTTP/1.1 302 Found');
      header('Location: ./kadai.php?err=mime');
      exit;
    }

    $image_filename = sprintf('%s.%s', bin2hex(random_bytes(16)), $ext);
    $dest = rtrim($UPLOAD_DIR, '/').'/'.$image_filename;

    if (!move_uploaded_file($_FILES['image']['tmp_name'], $dest)) {
      header('HTTP/1.1 302 Found');
      header('Location: ./kadai.php?err=move');
      exit;
    }
    @chmod($dest, 0644);
  }

  // INSERT
  $sql = "INSERT INTO bbs_entries (body, image_filename) VALUES (:body, :image_filename)";
  $stmt = $dbh->prepare($sql);
  $stmt->execute([
    ':body' => $body,
    ':image_filename' => $image_filename,
  ]);

  header('HTTP/1.1 302 Found');
  header('Location: ./kadai.php');
  exit;
}

// ===== 一覧取得 =====
$stmt = $dbh->prepare('SELECT id, body, image_filename, created_at FROM bbs_entries ORDER BY created_at DESC');
$stmt->execute();
$entries = $stmt->fetchAll();
?>
<!doctype html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <title>掲示板</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
  /* ここにCSS（省略せず） */
  </style>
</head>
<body>
  <h1>掲示板</h1>

  <?php if (!empty($_GET['err'])): ?>
    <div class="err">
      <?php
        $map = [
          'body' => '本文は1〜2000文字で入力してください。',
          'size' => '画像は5MB以下にしてください。',
          'mime' => '画像は jpg / png / gif / webp のみ対応です。',
          'move' => '画像の保存に失敗しました。'
        ];
        echo htmlspecialchars($map[$_GET['err']] ?? 'エラーが発生しました。', ENT_QUOTES, 'UTF-8');
      ?>
    </div>
  <?php endif; ?>

  <form method="POST" action="./kadai.php" enctype="multipart/form-data">
    <label for="body">本文（1〜2000文字）</label>
    <textarea id="body" name="body" maxlength="2000" required></textarea>
    <div style="margin:.75rem 0;">
      <label for="imageInput">画像（任意・5MBまで / jpg, png, gif, webp）</label><br>
      <input type="file" accept="image/*" name="image" id="imageInput">
    </div>
    <button type="submit">送信</button>
  </form>

  <h2>投稿一覧</h2>
  <?php foreach ($entries as $entry): ?>
    <div class="post">
      <div class="meta">
        #<?= (int)$entry['id'] ?> /
        <?= htmlspecialchars($entry['created_at'], ENT_QUOTES, 'UTF-8') ?>
      </div>
      <div class="content">
        <?= nl2br(htmlspecialchars($entry['body'], ENT_QUOTES, 'UTF-8')) ?>
        <?php if (!empty($entry['image_filename'])): ?>
          <img src="/image/<?= rawurlencode($entry['image_filename']) ?>" alt="attached">
        <?php endif; ?>
      </div>
    </div>
  <?php endforeach; ?>

  <script>
  document.addEventListener("DOMContentLoaded", () => {
    const imageInput = document.getElementById("imageInput");
    if (!imageInput) return;
    imageInput.addEventListener("change", () => {
      if (imageInput.files.length < 1) return;
      if (imageInput.files[0].size > 5 * 1024 * 1024) {
        alert("5MB以下のファイルを選んでください。");
        imageInput.value = "";
      }
    });
  });
  </script>
</body>
</html>
```

---

## Dockerfile
```dockerfile
FROM php:8.4-fpm-alpine AS php

RUN docker-php-ext-install pdo_mysql

RUN install -o www-data -g www-data -d /var/www/upload/image/

RUN echo -e "post_max_size = 5M\nupload_max_filesize = 5M" >> ${PHP_INI_DIR}/php.ini
```

---

## MySQL テーブル作成
```sql
CREATE TABLE `example_db`.`bbs_entries` (
  `id` INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  `body` TEXT NOT NULL,
  `image_filename` VARCHAR(255),
  `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
```
