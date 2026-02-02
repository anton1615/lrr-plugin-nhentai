package LANraragi::Plugin::Download::nHentai;

use strict;
use warnings;
no warnings 'uninitialized';

use lib '/home/koyomi/lanraragi/lib';
use LANraragi::Utils::Logging qw(get_plugin_logger);
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );

sub plugin_info {
    return (
        name         => "nHentai Downloader",
        type         => "download",
        namespace    => "nhdl",
        author       => "Gemini CLI",
        version      => "2.4",
        description  => "Downloads galleries from nHentai with in-plugin ZIP packaging using Archive::Zip. (v2.4 Fixed)",
        # 修正: 正確的正則表達式
        url_regex    => 'https?://nhentai\.net/g/\d+/?'
    );
}

sub provide_url {
    shift;
    my ($lrr_info, %params) = @_;
    my $logger = get_plugin_logger();
    my $url = $lrr_info->{url};

    $logger->info("--- nHentai Mojo v2.4 Triggered: $url ---");

    my $ua = $lrr_info->{user_agent};
    $ua->max_redirects(5);

    my $tx = $ua->get($url);
    
    # 檢查是否有回應
    unless ($tx && $tx->result) {
        $logger->error("No response received from nHentai");
        return ( error => "nHentai access failed. No response received." );
    }
    
    my $res = $tx->result;

    unless ($res->is_success) {
        $logger->error("Access failed: " . $res->code);
        return ( error => "nHentai access failed (HTTP " . $res->code . "). Check cookies/Cloudflare." );
    }

    my $html = $res->body;
    
    # 1. 提取標題
    my $title = "";
    if ($html =~ m|<h1 class="title">.*?<span class="pretty">(.*?)</span>|is) {
        $title = $1;
    }

    # 2. 提取 Media ID (修正: 使用 \d+ 而非 \\d+)
    unless ($html =~ m|/galleries/(\d+)/|i) {
        $logger->error("Could not find media ID in HTML");
        return ( error => "Could not parse nHentai content - no media ID found." );
    }
    my $media_id = $1;
    
    # 3. 提取總頁數 (修正: 使用 \d+ 而非 \\d+)
    my $num_pages = 0;
    if ($html =~ m|<span class="name">(\d+)</span>|i) {
        $num_pages = $1;
    } elsif ($html =~ m|(\d+)\s*pages|i) {
        $num_pages = $1;
    }

    if ($num_pages <= 0) {
        $logger->error("Could not determine page count");
        return ( error => "Could not parse nHentai content - no page count found." );
    }

    $logger->info("Found Media ID: $media_id, Pages: $num_pages, Title: $title");
    
    # 偵測圖片格式
    my $ext = "jpg";
    if ($html =~ m|/galleries/$media_id/1\.(png|webp|jpg|gif)|i) { 
        $ext = $1; 
    }

    # 檢查 tempdir
    unless ($lrr_info->{tempdir} && -d $lrr_info->{tempdir}) {
        $logger->error("No valid tempdir provided");
        return ( error => "No temporary directory available." );
    }

    my $work_dir = $lrr_info->{tempdir} . "/nh_$media_id";
    unless (-d $work_dir) {
        mkdir $work_dir or do {
            $logger->error("Failed to create work directory: $!");
            return ( error => "Failed to create work directory." );
        };
    }
    
    $logger->info("Downloading $num_pages images to $work_dir...");
    
    my $download_count = 0;
    for (my $i = 1; $i <= $num_pages; $i++) {
        my $img_url = "https://i.nhentai.net/galleries/$media_id/$i.$ext";
        my $save_to = sprintf("%s/%03d.%s", $work_dir, $i, $ext);
        
        eval {
            my $img_tx = $ua->get($img_url);
            if ($img_tx && $img_tx->result && $img_tx->result->is_success) {
                $img_tx->result->save_to($save_to);
                if (-e $save_to && -s $save_to) {
                    $download_count++;
                }
            } else {
                $logger->warn("Image $i failed: " . ($img_tx && $img_tx->result ? $img_tx->result->code : "No response"));
            }
        };
        if ($@) {
            $logger->warn("Image $i download exception: $@");
        }
    }

    $logger->info("Downloaded $download_count of $num_pages images");

    if ($download_count == 0) {
        return ( error => "No images were downloaded successfully." );
    }

    # 建立安全的檔名 - 只使用 media_id 以避免檔名問題
    my $safe_filename = "nhentai_$media_id";
    
    my $zip_path = $lrr_info->{tempdir} . "/$safe_filename.zip";
    
    # 如果檔案已存在，先刪除
    unlink $zip_path if -e $zip_path;
    
    my $zip = Archive::Zip->new();
    
    $logger->info("Packaging images into $zip_path using Archive::Zip...");
    
    my $added_count = 0;
    for (my $i = 1; $i <= $num_pages; $i++) {
        my $img_file = sprintf("%03d.%s", $i, $ext);
        my $img_full_path = "$work_dir/$img_file";
        if (-e $img_full_path && -s $img_full_path) {
            my $member = $zip->addFile($img_full_path, $img_file);
            if ($member) {
                $member->desiredCompressionMethod(COMPRESSION_STORED);  # 不壓縮圖片，加快速度
                $added_count++;
            }
        }
    }

    $logger->info("Added $added_count files to archive");

    if ($added_count == 0) {
        return ( error => "No valid files to add to archive." );
    }
    
    my $write_status = $zip->writeToFileNamed($zip_path);
    unless ($write_status == AZ_OK) {
        $logger->error("Archive::Zip failed to write (status: $write_status): $!");
        return ( error => "ZIP packaging failed." );
    }
    
    # 驗證 ZIP 檔案
    unless (-e $zip_path) {
        $logger->error("ZIP file does not exist after write: $zip_path");
        return ( error => "ZIP file was not created." );
    }
    
    my $zip_size = -s $zip_path;
    unless ($zip_size && $zip_size > 0) {
        $logger->error("ZIP file is empty: $zip_path");
        return ( error => "ZIP file is empty." );
    }

    $logger->info("Download and packaging successful: $zip_path (size: $zip_size bytes)");
    
    # 清理工作目錄中的圖片檔案
    for (my $i = 1; $i <= $num_pages; $i++) {
        my $img_file = sprintf("%03d.%s", $i, $ext);
        my $img_full_path = "$work_dir/$img_file";
        unlink $img_full_path if -e $img_full_path;
    }
    rmdir $work_dir;
    
    # 返回檔案路徑給 LANraragi
    return ( file_path => $zip_path );
}

1;
