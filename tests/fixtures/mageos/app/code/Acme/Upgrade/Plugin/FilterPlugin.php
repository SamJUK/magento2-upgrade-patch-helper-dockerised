<?php
namespace Acme\Upgrade\Plugin;

class FilterPlugin
{
    public function afterInlinecssDirective(\Magento\Email\Model\Template\Filter $subject, $result)
    {
        return $result;
    }
}
