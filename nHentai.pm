package LANraragi::Plugin::Download::nHentai;

use strict;
use warnings;
no warnings 'uninitialized';

use LANraragi::Utils::Logging qw(get_plugin_logger);

sub plugin_info {
    return (
        name         => "nHentai Downloader",
        type         => "download",
        namespace    => "nhdl",
        author       => "Gemini CLI",
        version      => "2.0",
        description  => "Downloads galleries from nHentai with in-plugin ZIP packaging to avoid encoding/header errors.",
        url_regex    => 'https?:\/\/nhentai\.net\/g\/\d+\/?'
    );
}

sub provide_url {
    shift;
    my ($lrr_info, %params) = @_;
    my $logger = get_plugin_logger();
    my $url = $lrr_info->{url};

    $logger->info("--- nHentai Mojo v2.0 Triggered: $url ---");

    # 使用 LRR 預先配置好的 UserAgent
    my $ua = $lrr_info->{user_agent};
    $ua->max_redirects(5);

    my $tx = $ua->get($url);
    my $res = $tx->result;

    if ($res->is_success) {
        my $html = $res->body;
        
        # 1. 提取標題
        my $title = "nhentai_download";
        if ($html =~ m|<h1 class="title"><span class="before">(.*?)</span><span class="pretty">(.*?)</span>|is) {
            $title = $2; # 使用漂亮的標題
            $title =~ s/[\/\\:\*\?"<>\|]/_/g; # 移除非法字元
            $title =~ s/^\s+|\s+$//g;
        }

        # 2. 提取 Media ID
        if ($html =~ m|/galleries/(\d+)/|i) {
            my $media_id = $1;
            
            # 3. 提取總頁數
            my $num_pages = 0;
            if ($html =~ m|<span class="name">(\d+)</span>|i || $html =~ m|<div>(\d+) pages</div>|i) {
                $num_pages = $1;
            }

            if ($media_id && $num_pages > 0) {
                $logger->info("Found Media ID: $media_id, Pages: $num_pages, Title: $title");
                
                # 偵測圖片格式
                my $ext = "jpg";
                if ($html =~ m|/galleries/$media_id/1\.(png|webp|jpg)|i) { $ext = $1; }

                if ($lrr_info->{tempdir}) {
                    my $work_dir = $lrr_info->{tempdir} . "/nh_$media_id";
                    mkdir $work_dir;
                    
                    $logger->info("Downloading $num_pages images to $work_dir...");
                    
                    for (my $i = 1; $i <= $num_pages; $i++) {
                        my $img_url = "https://i.nhentai.net/galleries/$media_id/$i.$ext";
                        my $save_to = sprintf("%s/%03d.%s", $work_dir, $i, $ext);
                        $ua->get($img_url)->result->save_to($save_to);
                    }

                    # 使用 LRR 內建的 Archive::Zip 打包 (或是直接回傳目錄由 LRR 處理，但回傳 ZIP 最穩)
                    my $zip_path = $lrr_info->{tempdir} . "/$title.zip";
                    $logger->info("Packaging images into $zip_path...");
                    
                    # 執行系統 zip 指令最簡單穩定
                    system("cd \"$work_dir\" && zip -jr \"$zip_path\" .");
                    
                    if (-s $zip_path) {
                        return ( file_path => $zip_path );
                    }
                }
            }
        }
    } else {
        $logger->error("Access failed: " . $res->code);
        return ( error => "nHentai access failed. Check cookies/Cloudflare." );
    }

    return ( error => "Could not parse nHentai content." );
}

1;
