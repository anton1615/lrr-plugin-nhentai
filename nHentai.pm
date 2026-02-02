package LANraragi::Plugin::Download::nHentai;

use strict;
use warnings;
no warnings 'uninitialized';

use lib '/home/koyomi/lanraragi/lib';
use LANraragi::Utils::Logging qw(get_plugin_logger);
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use JSON;
use File::Path qw(remove_tree);

sub plugin_info {
    return (
        name        => "nHentai Downloader",
        type        => "download",
        namespace   => "nhdl",
        author      => "Gemini CLI",
        version     => "3.0",
        description => "Downloads galleries from nHentai (v3.0 JSON parsing)",
        url_regex   => "https?://nhentai\\.net/g/\\d+/?"
    );
}

sub provide_url {
    shift;
    my ($lrr_info, %params) = @_;
    my $logger = get_plugin_logger();
    my $url = $lrr_info->{url};

    $logger->info("=== nHentai Downloader v3.0 Start ===");
    $logger->info("URL: $url");

    # 檢查 tempdir
    my $tempdir = $lrr_info->{tempdir};
    unless ($tempdir && -d $tempdir) {
        $logger->error("tempdir is invalid: $tempdir");
        return ( error => "Invalid tempdir" );
    }

    my $ua = $lrr_info->{user_agent};
    $ua->max_redirects(5);

    # 從 URL 提取 gallery ID
    my $gallery_id;
    if ($url =~ m|nhentai\.net/g/(\d+)|) {
        $gallery_id = $1;
        $logger->info("Gallery ID from URL: $gallery_id");
    } else {
        $logger->error("Cannot extract gallery ID from URL");
        return ( error => "Invalid nHentai URL" );
    }

    # 使用 API 獲取資訊（更可靠）
    my $api_url = "https://nhentai.net/api/gallery/$gallery_id";
    $logger->info("Fetching API: $api_url");
    
    my $tx = $ua->get($api_url);
    my $res = $tx->result;

    unless ($res && $res->is_success) {
        my $code = $res ? $res->code : "no response";
        $logger->error("API request failed: $code");
        return ( error => "nHentai API access failed (code: $code). Check cookies/Cloudflare." );
    }

    my $json_text = $res->body;
    $logger->debug("API Response length: " . length($json_text));

    my $data;
    eval {
        $data = decode_json($json_text);
    };
    if ($@) {
        $logger->error("JSON parse error: $@");
        return ( error => "Failed to parse nHentai API response" );
    }

    # 提取資訊
    my $media_id = $data->{media_id};
    my $num_pages = $data->{num_pages};
    my $title = $data->{title}{english} || $data->{title}{japanese} || "nhentai_$gallery_id";
    my $images = $data->{images}{pages};

    unless ($media_id && $num_pages && $images) {
        $logger->error("Missing data - media_id: $media_id, pages: $num_pages");
        return ( error => "Incomplete data from nHentai API" );
    }

    $logger->info("Media ID: $media_id, Pages: $num_pages, Title: $title");

    # 建立工作目錄
    my $work_dir = "$tempdir/nh_$gallery_id";
    mkdir $work_dir unless -d $work_dir;

    # 下載圖片
    my %ext_map = ( 'j' => 'jpg', 'p' => 'png', 'w' => 'webp', 'g' => 'gif' );
    my @downloaded_files;

    for (my $i = 0; $i < $num_pages; $i++) {
        my $page_num = $i + 1;
        my $img_type = $images->[$i]{t} || 'j';
        my $ext = $ext_map{$img_type} || 'jpg';
        
        my $img_url = "https://i.nhentai.net/galleries/$media_id/$page_num.$ext";
        my $filename = sprintf("%04d.%s", $page_num, $ext);
        my $save_path = "$work_dir/$filename";

        $logger->debug("Downloading page $page_num: $img_url");

        my $img_tx = $ua->get($img_url);
        my $img_res = $img_tx->result;

        if ($img_res && $img_res->is_success) {
            eval { $img_res->save_to($save_path); };
            if ($@ || !-s $save_path) {
                $logger->warn("Failed to save page $page_num: $@");
            } else {
                push @downloaded_files, $filename;
            }
        } else {
            $logger->warn("Failed to download page $page_num");
        }
    }

    $logger->info("Downloaded " . scalar(@downloaded_files) . " of $num_pages images");

    if (scalar(@downloaded_files) == 0) {
        return ( error => "No images downloaded" );
    }

    # 建立 ZIP 檔案 (使用安全檔名)
    my $safe_filename = "nhentai_$gallery_id.zip";
    my $zip_path = "$tempdir/$safe_filename";

    $logger->info("Creating ZIP: $zip_path");

    my $zip = Archive::Zip->new();

    foreach my $filename (sort @downloaded_files) {
        my $full_path = "$work_dir/$filename";
        if (-e $full_path && -s $full_path) {
            my $member = $zip->addFile($full_path, $filename);
            $member->desiredCompressionLevel(COMPRESSION_STORED);
        }
    }

    my $zip_result = $zip->writeToFileNamed($zip_path);
    if ($zip_result != AZ_OK) {
        $logger->error("ZIP write failed: $zip_result");
        return ( error => "Failed to create ZIP file" );
    }

    # 驗證 ZIP 檔案
    unless (-e $zip_path && -s $zip_path > 0) {
        $logger->error("ZIP file is empty or missing");
        return ( error => "ZIP file creation failed" );
    }

    my $zip_size = -s $zip_path;
    $logger->info("ZIP created successfully: $zip_path ($zip_size bytes)");

    # 清理工作目錄
    eval { remove_tree($work_dir); };

    $logger->info("=== nHentai Downloader Complete ===");

    # 返回檔案路徑
    return ( file_path => $zip_path );
}

1;