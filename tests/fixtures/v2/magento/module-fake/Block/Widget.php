<?php
namespace Magento\FakeModule\Block;

class Widget
{
    public function render(): string
    {
        return 'v2';
    }

    public function getTitle(): string
    {
        return 'Widget Title';
    }
}
